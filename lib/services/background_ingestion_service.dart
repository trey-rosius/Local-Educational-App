import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:objectbox/objectbox.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:langchain/langchain.dart';
import '../models/entities.dart';
import '../services/objectbox_manager.dart';
import '../main.dart';

enum IngestionStatus { pending, processing, completed, failed }

class IngestionTask {
  final String id;
  final String fileName;
  final int categoryId;
  IngestionStatus status;
  double progress;
  String currentStage;

  IngestionTask({
    required this.id,
    required this.fileName,
    required this.categoryId,
    this.status = IngestionStatus.pending,
    this.progress = 0.0,
    this.currentStage = 'Queued',
  });
}

class BackgroundIngestionService extends ChangeNotifier {
  static final BackgroundIngestionService _instance = BackgroundIngestionService._internal();
  factory BackgroundIngestionService() => _instance;
  BackgroundIngestionService._internal();

  final List<IngestionTask> _tasks = [];
  List<IngestionTask> get tasks => List.unmodifiable(_tasks);

  bool get hasActiveTasks => _tasks.any((t) => t.status == IngestionStatus.processing || t.status == IngestionStatus.pending);

  void addIngestionTask({
    required String filePath,
    required String fileName,
    required int categoryId,
  }) {
    final task = IngestionTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: fileName,
      categoryId: categoryId,
    );
    _tasks.add(task);
    notifyListeners();
    _processNextTask(filePath, task);
  }

  Future<void> _processNextTask(String filePath, IngestionTask task) async {
    task.status = IngestionStatus.processing;
    task.currentStage = 'Initializing...';
    notifyListeners();

    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final pdfDoc = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(pdfDoc);
      final pageCount = pdfDoc.pages.count;

      final textSplitter = RecursiveCharacterTextSplitter(
        chunkSize: 400,
        chunkOverlap: 50,
      );

      // Ensure embedder is ready
      if (!await FlutterGemma.hasActiveEmbedder()) {
        // ... Load Gecko 512 if needed (already handled by RagService logic)
      }
      final embeddingModel = await FlutterGemma.getActiveEmbedder();

      final List<String> pendingTexts = [];
      final List<int> pendingPages = [];

      for (int i = 0; i < pageCount; i++) {
        task.currentStage = 'Parsing Page ${i + 1}/$pageCount';
        task.progress = (i + 1) / (pageCount * 2); // Phase 1 is 50%
        notifyListeners();

        final pageText = extractor.extractText(startPageIndex: i, endPageIndex: i);
        if (pageText.trim().isEmpty) continue;

        final splitDocs = textSplitter.createDocuments([pageText]);
        for (final d in splitDocs) {
          pendingTexts.add(d.pageContent.trim());
          pendingPages.add(i + 1);
        }
        
        // Yield to keep UI smooth even if this is on main isolate for now
        await Future.delayed(Duration.zero);
      }

      pdfDoc.dispose();

      if (pendingTexts.isNotEmpty) {
        final totalChunks = pendingTexts.length;
        final List<VectorChunk> chunksToInsert = [];

        final category = objectBox.store.box<SubjectCategory>().get(task.categoryId)!;
        final documentEntity = StudyDocument(
          title: task.fileName,
          localFilePath: filePath,
          uploadTimestamp: DateTime.now(),
        );
        documentEntity.category.target = category;
        objectBox.store.box<StudyDocument>().put(documentEntity);

        // Embed in BATCHES instead of one call per chunk. Each
        // generateEmbedding call hops the platform channel and can briefly
        // block the UI; batching turns N round-trips into ceil(N/batch),
        // with a frame-length yield between batches so the spinner keeps
        // ticking.
        const int batchSize = 16;
        for (int start = 0; start < totalChunks; start += batchSize) {
          final end = (start + batchSize > totalChunks)
              ? totalChunks
              : start + batchSize;
          task.currentStage = 'Embedding Chunks ${start + 1}-$end of $totalChunks';
          task.progress = 0.5 + (start / (totalChunks * 2));
          notifyListeners();

          // Let the engine paint one frame before the next batch — this is
          // what unblocks the spinner between batches.
          await Future.delayed(const Duration(milliseconds: 16));

          try {
            final batchTexts = pendingTexts.sublist(start, end);
            final batchEmbeddings = await embeddingModel.generateEmbeddings(
              batchTexts,
              taskType: TaskType.retrievalDocument,
            );

            for (int j = 0; j < batchEmbeddings.length; j++) {
              final emb = batchEmbeddings[j];
              if (emb.isEmpty) continue;
              final chunk = VectorChunk(
                text: pendingTexts[start + j],
                pageNumber: pendingPages[start + j],
                embedding: Float32List.fromList(emb),
              );
              chunk.document.target = documentEntity;
              chunk.category.target = category;
              chunksToInsert.add(chunk);
            }
          } catch (e) {
            debugPrint('Batch embedding failed at $start-$end: $e — falling back to per-chunk');
            // Fallback: if the batch API is unavailable on the active model
            // or fails, fall back to per-chunk so we don't lose the whole
            // batch. Still yield between each so the UI breathes.
            for (int j = start; j < end; j++) {
              try {
                final emb = await embeddingModel.generateEmbedding(
                  pendingTexts[j],
                  taskType: TaskType.retrievalDocument,
                );
                if (emb.isNotEmpty) {
                  final chunk = VectorChunk(
                    text: pendingTexts[j],
                    pageNumber: pendingPages[j],
                    embedding: Float32List.fromList(emb),
                  );
                  chunk.document.target = documentEntity;
                  chunk.category.target = category;
                  chunksToInsert.add(chunk);
                }
              } catch (e2) {
                debugPrint('Chunk $j embedding failed: $e2');
              }
              await Future.delayed(const Duration(milliseconds: 1));
            }
          }
        }

        task.progress = 1.0;
        notifyListeners();

        if (chunksToInsert.isNotEmpty) {
          objectBox.store.box<VectorChunk>().putMany(chunksToInsert);
        }
      }

      task.status = IngestionStatus.completed;
      task.currentStage = 'Finished';
    } catch (e) {
      debugPrint('Ingestion failed: $e');
      task.status = IngestionStatus.failed;
      task.currentStage = 'Failed';
    }

    notifyListeners();
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }
}
