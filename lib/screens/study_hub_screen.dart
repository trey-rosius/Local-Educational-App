import 'dart:ui';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide Badge;
import '../widgets/glass_theme.dart';
import '../models/entities.dart';
import '../services/study_material_service.dart';
import 'workshop_screen.dart';
import '../services/rag_service.dart';
import '../widgets/educational_widgets.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/knowledge_share_service.dart';
import 'package:http/http.dart' as http;
import '../services/tts_service.dart';
import '../main.dart';
import '../utils/json_utils.dart';
import '../services/background_generation_service.dart';
import '../services/background_ingestion_service.dart';

class StudyHubScreen extends StatefulWidget {
  final SubjectCategory category;
  final StudyMaterialService materialService;
  final RagService ragService;

  const StudyHubScreen({
    super.key,
    required this.category,
    required this.materialService,
    required this.ragService,
  });

  @override
  State<StudyHubScreen> createState() => _StudyHubScreenState();
}

class _StudyHubScreenState extends State<StudyHubScreen> {
  bool _isGenerating = false;
  List<GeneratedStudyMaterial> _materials = [];
  final TtsService _ttsService = TtsService();
  final KnowledgeShareService _shareService = KnowledgeShareService();

  // Track which failed task IDs we've already surfaced so the snackbar
  // doesn't keep re-firing on every notifyListeners() tick.
  final Set<String> _surfacedFailureIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadMaterials();
    BackgroundGenerationService().addListener(_onTasksChanged);
    BackgroundIngestionService().addListener(_onTasksChanged);
  }

  void _onTasksChanged() {
    if (!mounted) return;
    _loadMaterials();
    // Surface any newly-failed generation tasks. Without this the spinner
    // just silently disappears when a task fails and the user has no idea
    // what went wrong.
    for (final task in BackgroundGenerationService().tasks) {
      if (task.status == GenerationStatus.failed &&
          !_surfacedFailureIds.contains(task.id)) {
        _surfacedFailureIds.add(task.id);
        final msg = task.errorMessage ?? 'Generation failed.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not generate ${task.type} "${task.title}":\n$msg',
            ),
            duration: const Duration(seconds: 12),
            action: SnackBarAction(
              label: 'Details',
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Generation failed: ${task.type}'),
                    content: SingleChildScrollView(
                      child: SelectableText(
                        msg,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          BackgroundGenerationService().removeTask(task.id);
                          Navigator.pop(ctx);
                        },
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    BackgroundGenerationService().removeListener(_onTasksChanged);
    BackgroundIngestionService().removeListener(_onTasksChanged);
    _ttsService.stop();
    _shareService.stopBroadcasting();
    super.dispose();
  }

  void _loadMaterials() {
    final materials = widget.materialService.getMaterialsForCategory(widget.category.id);
    setState(() {
      _materials = materials;
    });
  }

  Map<String, List<GeneratedStudyMaterial>> get _groupedMaterials {
    final groups = <String, List<GeneratedStudyMaterial>>{};
    for (var m in _materials) {
      groups.putIfAbsent(m.type, () => []).add(m);
    }
    return groups;
  }

  Future<void> _generate(
    String type, {
    int count = 10,
    QuizDifficulty difficulty = QuizDifficulty.medium,
  }) async {
    try {
      final prompt = await widget.materialService.buildPrompt(
        category: widget.category,
        type: type,
        count: count,
        difficulty: difficulty,
      );

      String? autoTitle;
      if (type == 'quiz') autoTitle = '${widget.category.name} · ${difficulty.label} · $count Q';
      else if (type == 'flashcards') autoTitle = '${widget.category.name} · $count cards';

      BackgroundGenerationService().addTask(
        type: type,
        prompt: prompt,
        title: autoTitle ?? type.toUpperCase(),
        categoryId: widget.category.id,
        materialService: widget.materialService,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generation task for $type added to background!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error queuing task: $e')),
        );
      }
    }
  }

  Future<void> _showQuizConfig() async {
    final result = await showModalBottomSheet<({QuizDifficulty difficulty, int count})>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      isScrollControlled: true,
      builder: (sheetContext) => const _QuizConfigSheet(),
    );
    if (result != null) {
      _generate('quiz', count: result.count, difficulty: result.difficulty);
    }
  }

  Future<void> _showWorkshopConfig() async {
    final result =
        await showModalBottomSheet<({WorkshopDepth depth, int lessonCount})>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      isScrollControlled: true,
      builder: (_) => const _WorkshopConfigSheet(),
    );
    if (result != null) {
      _generateWorkshop(
        depth: result.depth,
        lessonCount: result.lessonCount,
      );
    }
  }

  Future<void> _generateWorkshop({
    required WorkshopDepth depth,
    required int lessonCount,
  }) async {
    final progress = ValueNotifier<({String stage, double value})>(
      (stage: 'Preparing...', value: 0.0),
    );

    // Show a glass progress dialog that mirrors the service's stage events.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (_) => _WorkshopProgressDialog(progress: progress),
    );

    try {
      final material = await widget.materialService.generateWorkshopMaterial(
        category: widget.category,
        lessonCount: lessonCount,
        depth: depth,
        onProgress: (stage, p) {
          progress.value = (stage: stage, value: p);
        },
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // dismiss progress
      _loadMaterials();
      // Hop straight into the workshop overview.
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WorkshopScreen(
            material: material,
            materialService: widget.materialService,
          ),
        ),
      ).then((_) => _loadMaterials());
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Workshop generation error: $e')),
      );
    }
  }

  Future<void> _addMoreDocuments() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result != null && result.files.single.path != null) {
      try {
        final filePath = await widget.ragService.savePdfToDevice(result.files.single, widget.category);
        
        BackgroundIngestionService().addIngestionTask(
          filePath: filePath,
          fileName: result.files.single.name,
          categoryId: widget.category.id,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Document ingestion added to background!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error adding document: $e')),
          );
        }
      }
    }
  }

  void _saveBadge(String name, String reason) {
    final badge = Badge(
      name: name,
      description: reason,
      dateEarned: DateTime.now(),
    );
    badge.category.target = widget.category;
    objectBox.store.box<Badge>().put(badge);
    debugPrint("Badge saved: $name");
  }

  Future<void> _renameMaterial(GeneratedStudyMaterial material) async {
    final controller = TextEditingController(text: material.title ?? material.type.toUpperCase());
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Material'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'New Title')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Rename')),
        ],
      ),
    );

    if (newTitle != null && newTitle.isNotEmpty) {
      material.title = newTitle;
      objectBox.store.box<GeneratedStudyMaterial>().put(material);
      _loadMaterials();
    }
  }

  void _deleteMaterial(GeneratedStudyMaterial material) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Material?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              objectBox.store.box<GeneratedStudyMaterial>().remove(material.id);
              Navigator.pop(context);
              _loadMaterials();
            }, 
            child: const Text('Delete', style: TextStyle(color: Colors.white))),
        ],
      ),
    );
  }

  void _shareMaterial(GeneratedStudyMaterial material) async {
    // Show a loading indicator while starting the server
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final shareUrl = await _shareService.startBroadcasting(material);
    
    if (mounted) Navigator.pop(context); // Remove loading

    if (shareUrl == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start local server. Check Wi-Fi.')),
        );
      }
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF001a33),
        title: const Row(
          children: [
            Icon(Icons.wifi_tethering, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Knowledge Broadcast', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your phone is broadcasting this material over local Wi-Fi.', 
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.blueAccent.withValues(alpha: 0.3), blurRadius: 10)],
              ),
              child: QrImageView(
                data: shareUrl,
                version: QrVersions.auto,
                size: 200.0,
              ),
            ),
            const SizedBox(height: 16),
            Text(material.title ?? material.type.toUpperCase(), 
              style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Keep this screen open until scanned', 
              style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _shareService.stopBroadcasting();
              Navigator.pop(context);
            }, 
            child: const Text('Stop Sharing')
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/bg.jpg"),
          fit: BoxFit.cover,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: AppBar(
                title: Text(
                  '${widget.category.name} Study Hub',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                backgroundColor: Colors.white.withOpacity(0.06),
                elevation: 0,
                iconTheme: const IconThemeData(color: Colors.white),
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 8),
                    child: Tooltip(
                      message: 'Add more PDFs to this subject',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _addMoreDocuments,
                          borderRadius: BorderRadius.circular(12),
                          child: Ink(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Colors.white.withOpacity(0.18)),
                            ),
                            child: const SizedBox(
                              width: 40,
                              height: 40,
                              child: Icon(
                                Icons.add_home_work_outlined,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: BackgroundGenerationService(),
                    builder: (context, _) {
                      if (!BackgroundGenerationService().hasActiveTasks) return const SizedBox.shrink();
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${BackgroundGenerationService().tasks.where((t) => t.status == GenerationStatus.processing || t.status == GenerationStatus.pending).length} active',
                                style: const TextStyle(color: Colors.white, fontSize: 8),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  ListenableBuilder(
                    listenable: BackgroundIngestionService(),
                    builder: (context, _) {
                      if (!BackgroundIngestionService().hasActiveTasks) return const SizedBox.shrink();
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Ingesting',
                                style: TextStyle(color: Colors.greenAccent.withOpacity(0.8), fontSize: 7),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
        body: Padding(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
          ),
          child: Column(
            children: [
              // Generation Menu (glass tiles)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: GlassTheme.panel(radius: 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildGenButton(
                                'Quiz',
                                Icons.quiz,
                                const Color(0xFF82B1FF),
                                _showQuizConfig),
                          ),
                          Expanded(
                            child: _buildGenButton(
                                'Map',
                                Icons.hub_outlined,
                                const Color(0xFFB388FF),
                                () => _generate('mind_map')),
                          ),
                          Expanded(
                            child: _buildGenButton(
                                'Summary',
                                Icons.summarize,
                                const Color(0xFF80D8FF),
                                () => _generate('summary')),
                          ),
                          Expanded(
                            child: _buildGenButton(
                                'Cards',
                                Icons.style,
                                const Color(0xFFFF80AB),
                                () => _generate('flashcards')),
                          ),
                          Expanded(
                            child: _buildGenButton(
                                'Workshop',
                                Icons.school_rounded,
                                const Color(0xFF7CE2C9),
                                _showWorkshopConfig),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Persistent Materials List
              Expanded(
                child: _materials.isEmpty
                    ? Center(
                        child: Text(
                          'No study materials yet.\nGenerate some above!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 14,
                          ),
                        ),
                      )
                    : _buildGroupedMaterials(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGenButton(
      String label, IconData icon, Color accent, VoidCallback onPressed) {
    final disabled = _isGenerating;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: disabled ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      accent.withOpacity(disabled ? 0.18 : 0.35),
                      accent.withOpacity(disabled ? 0.08 : 0.18),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: accent.withOpacity(disabled ? 0.25 : 0.55),
                  ),
                ),
                child: Icon(icon, color: accent, size: 26),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(disabled ? 0.5 : 0.9),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMaterialCard(GeneratedStudyMaterial material) {
    if (material.type == 'workshop') {
      return _buildWorkshopCard(material);
    }
    final dateStr = DateFormat('MMM d, HH:mm').format(material.dateCreated);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            decoration: GlassTheme.panel(radius: 20),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: Colors.white.withOpacity(0.06),
              ),
              child: ExpansionTile(
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                childrenPadding:
                    const EdgeInsets.fromLTRB(12, 0, 12, 12),
                iconColor: Colors.white.withOpacity(0.85),
                collapsedIconColor: Colors.white.withOpacity(0.85),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.white.withOpacity(0.18)),
                  ),
                  child: Icon(_getIconForType(material.type),
                      color: const Color(0xFF82B1FF), size: 20),
                ),
                title: Text(
                  material.title ?? material.type.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Generated on $dateStr',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.65),
                    fontSize: 12,
                  ),
                ),
                trailing: PopupMenuButton<String>(
                  color: const Color(0xFF1B1F2A),
                  icon: Icon(Icons.more_horiz,
                      color: Colors.white.withOpacity(0.85)),
                  onSelected: (value) {
                    if (value == 'share') _shareMaterial(material);
                    if (value == 'rename') _renameMaterial(material);
                    if (value == 'delete') _deleteMaterial(material);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                        value: 'share',
                        child: ListTile(
                            leading: Icon(Icons.share,
                                size: 20, color: Colors.white),
                            title: Text('Share QR',
                                style: TextStyle(color: Colors.white)))),
                    PopupMenuItem(
                        value: 'rename',
                        child: ListTile(
                            leading: Icon(Icons.edit,
                                size: 20, color: Colors.white),
                            title: Text('Rename',
                                style: TextStyle(color: Colors.white)))),
                    PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                            leading: Icon(Icons.delete,
                                size: 20, color: Colors.redAccent),
                            title: Text('Delete',
                                style: TextStyle(color: Colors.redAccent)))),
                  ],
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: Colors.white.withOpacity(0.10)),
                    ),
                    child: _renderContent(material),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'quiz': return Icons.quiz;
      case 'mind_map': return Icons.hub_outlined;
      case 'summary': return Icons.summarize;
      case 'flashcards': return Icons.style;
      case 'workshop': return Icons.school_rounded;
      default: return Icons.book;
    }
  }

  Widget _renderContent(GeneratedStudyMaterial material) {
    try {
      if (material.type == 'quiz') {
        final cleanJson = JsonUtils.extractAndCleanJson(material.contentJson);
        final data = jsonDecode(cleanJson);
        List<dynamic> questions = [];
        if (data is Map) {
          questions = data['questions'] ?? [];
        } else if (data is List) {
          questions = data;
        }
        
        return QuizCard(
          subject: widget.category.name,
          questions: questions,
          onComplete: (score, total) {
            if (score == total) {
              _saveBadge('Mastery', 'Perfect score in ${widget.category.name}!');
            }
            showDialog(
              context: context,
              builder: (context) => Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                insetPadding: const EdgeInsets.symmetric(horizontal: 32),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: GlassTheme.panel(radius: 24, strong: true),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (score == total)
                            const BadgeCard(
                              badgeName: 'Mastery',
                              reason:
                                  'Perfect score! You have mastered this concept.',
                            )
                          else ...[
                            const Icon(Icons.stars,
                                size: 64, color: Colors.amber),
                            const SizedBox(height: 16),
                            Text('Great Job!',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(color: Colors.white)),
                          ],
                          const SizedBox(height: 16),
                          Text('You scored $score out of $total',
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.85))),
                          const SizedBox(height: 24),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF82B1FF),
                              backgroundColor:
                                  const Color(0xFF82B1FF).withOpacity(0.18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(
                                    color: const Color(0xFF82B1FF)
                                        .withOpacity(0.55)),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 22, vertical: 10),
                            ),
                            child: const Text('Back to Library',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      } else if (material.type == 'mind_map') {
        final cleanJson = JsonUtils.extractAndCleanJson(material.contentJson);
        final data = jsonDecode(cleanJson);
        return MindMapWidget(data: data);
      } else if (material.type == 'summary') {
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blueGrey.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      if (_ttsService.isPlaying) {
                        _ttsService.stop();
                        setState(() {});
                      } else {
                        _ttsService.speak(material.contentJson);
                        setState(() {});
                      }
                    },
                    icon: Icon(_ttsService.isPlaying ? Icons.stop : Icons.play_circle_outline),
                    label: Text(_ttsService.isPlaying ? 'Stop' : 'Listen'),
                  ),
                ],
              ),
              Text(material.contentJson, style: const TextStyle(height: 1.5, color: Colors.white)),
            ],
          ),
        );
      } else if (material.type == 'flashcards') {
        final cleanJson = JsonUtils.extractAndCleanJson(material.contentJson);
        final data = jsonDecode(cleanJson);
        List<dynamic> cards = [];
        if (data is Map) {
          cards = data['cards'] ?? [];
        } else if (data is List) {
          cards = data;
        }
        return FlashcardCarousel(cards: cards);
      }
    } catch (e) {
      return Text('Content Error: $e\nRaw: ${material.contentJson}', style: const TextStyle(color: Colors.white));
    }
    return const Text('Unsupported type', style: TextStyle(color: Colors.white));
  }


  Widget _buildGroupedMaterials() {
    final groups = _groupedMaterials;
    final types = groups.keys.toList()..sort();
    
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        MediaQuery.of(context).padding.bottom + 16,
      ),
      itemCount: types.length,
      itemBuilder: (context, index) {
        final type = types[index];
        final items = groups[type]!;
        
        return _buildFolder(type, items);
      },
    );
  }

  Widget _buildFolder(String type, List<GeneratedStudyMaterial> items) {
    final label = _getTypeLabel(type);
    final icon = _getIconForType(type);
    final color = _getTypeColor(type);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: ExpansionTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withOpacity(0.4)),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              title: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                '${items.length} item${items.length == 1 ? '' : 's'}',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 12,
                ),
              ),
              trailing: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white.withOpacity(0.7),
              ),
              children: items.map((m) => _buildMaterialCard(m)).toList(),
            ),
          ),
        ),
      ),
    );
  }

  String _getTypeLabel(String type) {
    switch (type) {
      case 'quiz': return 'Quizzes';
      case 'mind_map': return 'Mind Maps';
      case 'summary': return 'Summaries';
      case 'flashcards': return 'Flashcards';
      case 'workshop': return 'Workshops';
      default: return type.toUpperCase();
    }
  }

  Color _getTypeColor(String type) {
    switch (type) {
      case 'quiz': return const Color(0xFF82B1FF);
      case 'mind_map': return const Color(0xFFB388FF);
      case 'summary': return const Color(0xFF80D8FF);
      case 'flashcards': return const Color(0xFFFF80AB);
      case 'workshop': return const Color(0xFF7CE2C9);
      default: return Colors.white;
    }
  }

  /// Custom card for workshop materials — shows progress + Resume button
  /// instead of the default expandable content panel.
  Widget _buildWorkshopCard(GeneratedStudyMaterial material) {
    final progress = widget.materialService.workshopProgress(material);
    final percent = (progress * 100).round();

    Map<String, dynamic> data;
    try {
      data = jsonDecode(JsonUtils.extractAndCleanJson(material.contentJson)) as Map<String, dynamic>;
    } catch (_) {
      data = const {};
    }
    final lessons = (data['lessons'] as List? ?? []);
    final completed =
        lessons.where((l) => (l as Map)['completed'] == true).length;
    final total = lessons.length;
    final started = data['startedAt'] != null;
    final title = (data['title'] ?? material.title ?? 'Workshop').toString();
    final description = (data['description'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => WorkshopScreen(
                      material: material,
                      materialService: widget.materialService,
                    ),
                  ),
                ).then((_) => _loadMaterials());
              },
              borderRadius: BorderRadius.circular(20),
              child: Ink(
                decoration: GlassTheme.panel(radius: 20),
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 14, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color:
                                  GlassTheme.success.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: GlassTheme.success
                                      .withOpacity(0.55)),
                            ),
                            child: const Icon(
                              Icons.school_rounded,
                              color: GlassTheme.success,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: GlassTheme.textPrimary,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$completed of $total lessons',
                                  style: const TextStyle(
                                    color: GlassTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '$percent%',
                            style: const TextStyle(
                              color: GlassTheme.success,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GlassTheme.textSecondary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          backgroundColor:
                              Colors.white.withOpacity(0.10),
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(
                                  GlassTheme.success),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  GlassTheme.accentBlue
                                      .withOpacity(0.45),
                                  GlassTheme.accentBlue
                                      .withOpacity(0.22),
                                ],
                              ),
                              borderRadius:
                                  BorderRadius.circular(999),
                              border: Border.all(
                                  color: GlassTheme.accentBlue
                                      .withOpacity(0.65)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  started
                                      ? Icons.east_rounded
                                      : Icons.play_arrow_rounded,
                                  color: GlassTheme.accentBlue,
                                  size: 14,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  started ? 'Resume' : 'Start',
                                  style: const TextStyle(
                                    color: GlassTheme.accentBlue,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          PopupMenuButton<String>(
                            color: const Color(0xFF1B1F2A),
                            icon: Icon(Icons.more_horiz,
                                color:
                                    Colors.white.withOpacity(0.85)),
                            onSelected: (value) {
                              if (value == 'rename') {
                                _renameMaterial(material);
                              } else if (value == 'delete') {
                                _deleteMaterial(material);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: ListTile(
                                  leading: Icon(Icons.edit,
                                      size: 20,
                                      color: Colors.white),
                                  title: Text('Rename',
                                      style: TextStyle(
                                          color: Colors.white)),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(Icons.delete,
                                      size: 20,
                                      color: Colors.redAccent),
                                  title: Text('Delete',
                                      style: TextStyle(
                                          color:
                                              Colors.redAccent)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass bottom sheet for picking quiz difficulty + question count.
///
/// Returns a record `(difficulty: ..., count: ...)` on confirm, or `null`
/// if the user dismissed the sheet.
class _QuizConfigSheet extends StatefulWidget {
  const _QuizConfigSheet();

  @override
  State<_QuizConfigSheet> createState() => _QuizConfigSheetState();
}

class _QuizConfigSheetState extends State<_QuizConfigSheet> {
  QuizDifficulty _difficulty = QuizDifficulty.medium;
  int _count = 10;

  static const _countOptions = [5, 10, 15, 20];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              decoration: GlassTheme.panel(radius: 28, strong: true),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF82B1FF).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: const Color(0xFF82B1FF)
                                  .withOpacity(0.55)),
                        ),
                        child: const Icon(
                          Icons.quiz_rounded,
                          color: Color(0xFF82B1FF),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'New Quiz',
                              style: TextStyle(
                                color: GlassTheme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Pick a difficulty and how many questions.',
                              style: TextStyle(
                                color: GlassTheme.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const _SectionLabel(label: 'Difficulty'),
                  const SizedBox(height: 8),
                  Row(
                    children: QuizDifficulty.values.map((d) {
                      final selected = d == _difficulty;
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: d == QuizDifficulty.values.last ? 0 : 8,
                          ),
                          child: _ChoiceChip(
                            label: d.label,
                            selected: selected,
                            accent: _accentForDifficulty(d),
                            onTap: () => setState(() => _difficulty = d),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel(label: 'Number of questions'),
                  const SizedBox(height: 8),
                  Row(
                    children: _countOptions.map((n) {
                      final selected = n == _count;
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: n == _countOptions.last ? 0 : 8,
                          ),
                          child: _ChoiceChip(
                            label: '$n',
                            selected: selected,
                            accent: GlassTheme.accentBlue,
                            onTap: () => setState(() => _count = n),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          foregroundColor:
                              Colors.white.withOpacity(0.85),
                        ),
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                      _PrimaryButton(
                        label: 'Generate',
                        accent: GlassTheme.accentBlue,
                        icon: Icons.auto_awesome_rounded,
                        onTap: () {
                          Navigator.pop<({QuizDifficulty difficulty, int count})>(
                            context,
                            (difficulty: _difficulty, count: _count),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _accentForDifficulty(QuizDifficulty d) {
    switch (d) {
      case QuizDifficulty.easy:
        return GlassTheme.success;
      case QuizDifficulty.medium:
        return GlassTheme.accentBlue;
      case QuizDifficulty.hard:
        return GlassTheme.danger;
    }
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: GlassTheme.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            gradient: selected
                ? LinearGradient(
                    colors: [
                      accent.withOpacity(0.35),
                      accent.withOpacity(0.18),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: selected ? null : Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accent.withOpacity(selected ? 0.65 : 0.28),
              width: selected ? 1.4 : 1.0,
            ),
          ),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? accent : GlassTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accent.withOpacity(0.45),
                accent.withOpacity(0.22),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withOpacity(0.65)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 18, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: accent, size: 18),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass bottom sheet for picking workshop depth + lesson count.
class _WorkshopConfigSheet extends StatefulWidget {
  const _WorkshopConfigSheet();

  @override
  State<_WorkshopConfigSheet> createState() => _WorkshopConfigSheetState();
}

class _WorkshopConfigSheetState extends State<_WorkshopConfigSheet> {
  WorkshopDepth _depth = WorkshopDepth.intermediate;
  int _lessonCount = 6;

  static const _lessonOptions = [4, 6, 8, 10];

  Color _accentForDepth(WorkshopDepth d) {
    switch (d) {
      case WorkshopDepth.beginner:
        return GlassTheme.success;
      case WorkshopDepth.intermediate:
        return GlassTheme.accentBlue;
      case WorkshopDepth.advanced:
        return GlassTheme.accentPurple;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              decoration: GlassTheme.panel(radius: 28, strong: true),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: GlassTheme.success.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color:
                                  GlassTheme.success.withOpacity(0.55)),
                        ),
                        child: const Icon(
                          Icons.school_rounded,
                          color: GlassTheme.success,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'New Workshop',
                              style: TextStyle(
                                color: GlassTheme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'A structured course built from your subject\'s documents.',
                              style: TextStyle(
                                color: GlassTheme.textSecondary,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const _SectionLabel(label: 'Depth'),
                  const SizedBox(height: 8),
                  Row(
                    children: WorkshopDepth.values.map((d) {
                      final selected = d == _depth;
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: d == WorkshopDepth.values.last ? 0 : 8,
                          ),
                          child: _ChoiceChip(
                            label: d.label,
                            selected: selected,
                            accent: _accentForDepth(d),
                            onTap: () => setState(() => _depth = d),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel(label: 'Number of lessons'),
                  const SizedBox(height: 8),
                  Row(
                    children: _lessonOptions.map((n) {
                      final selected = n == _lessonCount;
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: n == _lessonOptions.last ? 0 : 8,
                          ),
                          child: _ChoiceChip(
                            label: '$n',
                            selected: selected,
                            accent: GlassTheme.success,
                            onTap: () =>
                                setState(() => _lessonCount = n),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: GlassTheme.borderSubtle),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 16, color: GlassTheme.textSecondary),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'We\'ll draft an outline now. Each lesson is generated when you open it for the first time.',
                            style: TextStyle(
                              color: GlassTheme.textSecondary,
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          foregroundColor:
                              Colors.white.withOpacity(0.85),
                        ),
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                      _PrimaryButton(
                        label: 'Create Workshop',
                        accent: GlassTheme.success,
                        icon: Icons.auto_awesome_rounded,
                        onTap: () {
                          Navigator.pop<({WorkshopDepth depth, int lessonCount})>(
                            context,
                            (depth: _depth, lessonCount: _lessonCount),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass progress dialog shown while a workshop outline is being generated.
class _WorkshopProgressDialog extends StatelessWidget {
  final ValueListenable<({String stage, double value})> progress;
  const _WorkshopProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            decoration: GlassTheme.panel(radius: 24, strong: true),
            child: ValueListenableBuilder<({String stage, double value})>(
              valueListenable: progress,
              builder: (context, p, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: GlassTheme.success.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color:
                                  GlassTheme.success.withOpacity(0.55)),
                        ),
                        child: const Icon(Icons.school_rounded,
                            color: GlassTheme.success, size: 18),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Building your workshop',
                        style: TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    p.stage,
                    style: const TextStyle(
                      color: GlassTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: p.value == 0 ? null : p.value,
                      minHeight: 8,
                      backgroundColor: Colors.white.withOpacity(0.10),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          GlassTheme.success),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
