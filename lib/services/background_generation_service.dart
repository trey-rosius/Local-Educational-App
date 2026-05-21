import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import '../models/entities.dart';
import '../services/objectbox_manager.dart';
import 'dart:convert';

import '../services/memory_guard.dart';
import '../services/notification_service.dart';
import '../services/study_material_service.dart';
import '../services/educational_tool_service.dart';
import '../models/model.dart';
import '../main.dart';

enum GenerationStatus { pending, processing, completed, failed }

class GenerationTask {
  final String id;
  final String type;
  final String prompt;
  final String title;
  final int categoryId;
  final StudyMaterialService materialService;
  GenerationStatus status;
  double progress;
  String? errorMessage;

  GenerationTask({
    required this.id,
    required this.type,
    required this.prompt,
    required this.title,
    required this.categoryId,
    required this.materialService,
    this.status = GenerationStatus.pending,
    this.progress = 0.0,
    this.errorMessage,
  });
}

class BackgroundGenerationService extends ChangeNotifier {
  static final BackgroundGenerationService _instance = BackgroundGenerationService._internal();
  factory BackgroundGenerationService() => _instance;
  BackgroundGenerationService._internal();

  final List<GenerationTask> _tasks = [];
  List<GenerationTask> get tasks => List.unmodifiable(_tasks);

  /// Hard upper bound on a single generation. Above this we consider the
  /// task hung (KV cache stuck, model in bad state, etc.) and fail it
  /// rather than letting the "1 active" spinner run forever. On-device
  /// 10-question quizzes can legitimately take 2-4 minutes on slower
  /// devices, so the timeout has to be generous.
  static const Duration _generationTimeout = Duration(minutes: 6);

  bool get hasActiveTasks => _tasks.any((t) => t.status == GenerationStatus.processing || t.status == GenerationStatus.pending);

  void addTask({
    required String type,
    required String prompt,
    required String title,
    required int categoryId,
    required StudyMaterialService materialService,
  }) {
    final task = GenerationTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: type,
      prompt: prompt,
      title: title,
      categoryId: categoryId,
      materialService: materialService,
    );
    _tasks.add(task);
    notifyListeners();
    _processNextTask();
  }

  Future<void> _processNextTask() async {
    final nextTask = _tasks.firstWhere(
      (t) => t.status == GenerationStatus.pending,
      orElse: () => GenerationTask(
        id: '',
        type: '',
        prompt: '',
        title: '',
        categoryId: 0,
        materialService: _tasks.isNotEmpty
            ? _tasks.first.materialService
            : (throw StateError('no materialService available')),
      ),
    );

    if (nextTask.id.isEmpty) return;

    nextTask.status = GenerationStatus.processing;
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    InferenceChat? chat;
    try {
      // Ensure model is loaded before inference.
      if (!FlutterGemma.hasActiveModel()) {
        final gemma4 = Model.gemma4_E2B;
        if (await FlutterGemma.isModelInstalled(gemma4.filename)) {
          await FlutterGemma.installModel(
            modelType: gemma4.modelType,
            fileType: gemma4.fileType,
          ).fromNetwork(gemma4.url).install();
        } else {
          throw 'Model not installed. Please download it from the home screen first.';
        }
      }

      // maxTokens comes from MemoryGuard — 4096 on desktop, 3072 in Lean
      // Memory Mode (default on 6 GB devices like iPhone 13 Pro Max).
      final model = await FlutterGemma
          .getActiveModel(maxTokens: MemoryGuard.instance.maxTokens);

      // Structured types use tool calling — the flutter_gemma runtime
      // constrains generation at the token level so the model literally
      // cannot emit broken JSON. No repair pipeline runs.
      final Tool? structuredTool = _toolForType(nextTask.type);

      // Sampling tuned for tool calling on Gemma E2B:
      // - temperature 0.3 (low but not greedy) avoids getting stuck in
      //   short repetition loops that greedy decoding (temp~0, topK=1) is
      //   prone to on long structured outputs.
      // - topK 40 + topP 0.95 follow Gemma's published guidance.
      chat = structuredTool != null
          ? await model.createChat(
              temperature: 0.3,
              topK: 40,
              topP: 0.95,
              supportsFunctionCalls: true,
              tools: [structuredTool],
              toolChoice: ToolChoice.required,
            )
          : await model.createChat(temperature: 0.1);

      final isolatedPrompt =
          "IMPORTANT: Focus ONLY on this new request. Ignore any previous context.\n\n${nextTask.prompt}";

      debugPrint(
          'BG: starting ${nextTask.type} task (prompt ~${isolatedPrompt.length} chars, '
          'tool=${structuredTool?.name ?? "none"})');

      // Run with a hard deadline so a hung native call can't pin "1 active"
      // forever (the user's "quiz still spinning after 20 minutes" report).
      final response = await () async {
        await chat!.addQuery(Message.text(text: isolatedPrompt));
        return chat.generateChatResponse();
      }()
          .timeout(_generationTimeout, onTimeout: () {
        throw 'Generation timed out after ${_generationTimeout.inMinutes} '
            'minutes. The model may be stuck or out of context. Please '
            'try again — lowering the question count often helps.';
      });

      // For tool-call types, the response is ideally a parsed Map. Some
      // Gemma fine-tunes don't fully honor `ToolChoice.required` and emit
      // a TextResponse anyway — in that case we fall back to treating the
      // text as a free-form JSON model output and let the repair pipeline
      // in saveMaterial sort it out. This is the same path non-tool types
      // use, so we always get *some* result rather than a silent failure.
      String? content;
      if (structuredTool != null) {
        Map<String, dynamic>? args;
        if (response is FunctionCallResponse &&
            response.name == structuredTool.name) {
          args = Map<String, dynamic>.from(response.args);
        } else if (response is ParallelFunctionCallResponse) {
          for (final call in response.calls) {
            if (call.name == structuredTool.name) {
              args = Map<String, dynamic>.from(call.args);
              break;
            }
          }
        }
        if (args != null) {
          content = jsonEncode(args);
          debugPrint('BG: tool call SUCCEEDED for ${nextTask.type}');
        } else if (response is TextResponse && response.token.isNotEmpty) {
          // Model ignored ToolChoice.required and emitted free-form text.
          // Fall through to the repair pipeline.
          debugPrint(
              'BG: tool call returned TextResponse for ${nextTask.type}; '
              'falling back to JSON repair. Length=${response.token.length}');
          content = response.token;
        }
      } else {
        final rawText = response is TextResponse ? response.token : '';
        if (rawText.isNotEmpty) content = rawText;
      }

      if (content == null || content.isEmpty) {
        throw 'The model returned an empty response. Please try again.';
      }

      // Route the save through StudyMaterialService.saveMaterial so the
      // semantic validators run (citation detection, empty filter, etc.).
      // For tool-call output the JSON is already valid so repair is a no-op.
      final category =
          objectBox.store.box<SubjectCategory>().get(nextTask.categoryId);
      if (category == null) {
        throw 'Category ${nextTask.categoryId} no longer exists.';
      }
      await nextTask.materialService.saveMaterial(
        category: category,
        type: nextTask.type,
        content: content,
        title: nextTask.title,
      );

      nextTask.status = GenerationStatus.completed;

      await NotificationService.showNotification(
        id: int.parse(nextTask.id.substring(nextTask.id.length - 5)),
        title: 'Generation Complete',
        body: 'Your ${nextTask.type} for "${nextTask.title}" is ready!',
      );
    } catch (e) {
      debugPrint('Generation failed: $e');
      nextTask.status = GenerationStatus.failed;
      nextTask.errorMessage = e.toString();
      // Surface failure in the same channel users already watch for
      // success — otherwise a failed task just silently disappears from
      // the "active" counter with no explanation.
      try {
        await NotificationService.showNotification(
          id: int.parse(nextTask.id.substring(nextTask.id.length - 5)),
          title: 'Generation Failed',
          body: 'Could not generate ${nextTask.type} "${nextTask.title}". '
              'Tap to retry.',
        );
      } catch (_) {}
    } finally {
      // Close the CHAT to release KV cache. Do NOT close the model — it's
      // a process-wide singleton, and `model.close()` followed by another
      // `getActiveModel()` returns a dangling pointer that double-frees
      // on the next inference ("pointer being freed was not allocated").
      try {
        await chat?.close();
      } catch (_) {}
      stopwatch.stop();
      debugPrint(
          'BG: ${nextTask.type} task ${nextTask.id} finished in '
          '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
          '(status=${nextTask.status.name})');
    }

    notifyListeners();
    _processNextTask();
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  /// Returns the function-calling [Tool] schema for content types that have
  /// one defined. Types not listed here fall back to text-mode generation
  /// + the JSON repair pipeline.
  Tool? _toolForType(String type) {
    switch (type) {
      case 'quiz':
        return EducationalToolService.quizTool;
      case 'flashcards':
        return EducationalToolService.flashcardsTool;
      // 'mind_map' to be added when its schema lands.
      default:
        return null;
    }
  }
}
