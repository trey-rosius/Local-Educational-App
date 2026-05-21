import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import '../services/rag_service.dart';
import '../services/auth_token_service.dart';
import '../main.dart';
import '../models/entities.dart';
import '../models/embedding_model.dart' as local_embedding;
import '../models/model.dart';
import '../objectbox.g.dart';
import '../widgets/glass_theme.dart';

class IngestionWorkflowScreen extends StatefulWidget {
  const IngestionWorkflowScreen({super.key});

  @override
  State<IngestionWorkflowScreen> createState() =>
      _IngestionWorkflowScreenState();
}

class _IngestionWorkflowScreenState extends State<IngestionWorkflowScreen> {
  final RagService _ragService = RagService(objectBox.store);
  final TextEditingController _categoryController = TextEditingController();

  int _step = 0;
  String _status = 'Ready to ingest';
  bool _isIngesting = false;
  double _progress = 0;
  bool _isImageSource = false;
  String _systemStatus = 'Initializing...';

  // Per-page and per-chunk counters surfaced by ingestDocument so the user
  // can see "Page 23 of 205" and "Chunk 87 of 412" instead of an opaque %.
  int _pageCurrent = 0;
  int _pageTotal = 0;
  int _chunkCurrent = 0;
  int _chunkTotal = 0;

  @override
  void initState() {
    super.initState();
    _checkModelActivation();
  }

  @override
  void dispose() {
    _categoryController.dispose();
    super.dispose();
  }

  Future<void> _checkModelActivation() async {
    try {
      bool hasEmbedder = await FlutterGemma.hasActiveEmbedder();
      if (!hasEmbedder) {
        setState(() => _systemStatus = 'Activating embedder...');
        final token = await AuthTokenService.loadToken();
        final model = local_embedding.EmbeddingModel.gecko512;
        await FlutterGemma.installEmbedder()
            .modelFromNetwork(model.url, token: token)
            .tokenizerFromNetwork(model.tokenizerUrl, token: token, iosPath: model.iosTokenizerPath)
            .install();
        await FlutterGemma.getActiveEmbedder();
      }

      if (!FlutterGemma.hasActiveModel()) {
        final gemma4 = Model.gemma4_E2B;
        if (await FlutterGemma.isModelInstalled(gemma4.filename)) {
          setState(() => _systemStatus = 'Activating Gemma 4...');
          await FlutterGemma.installModel(modelType: gemma4.modelType, fileType: gemma4.fileType)
              .fromNetwork(gemma4.url)
              .install();
          await FlutterGemma.getActiveModel(
            maxTokens: gemma4.maxTokens,
            supportImage: gemma4.supportImage,
            maxNumImages: gemma4.maxNumImages,
          );
        }
      }

      setState(() => _systemStatus = 'System Ready');
    } catch (e) {
      setState(() => _systemStatus = 'Init error: $e');
    }
  }

  String _labelForStep(int step) {
    switch (step) {
      case 1:
        return 'Saving Physical File...';
      case 2:
        return 'Registering Metadata...';
      case 3:
        return _isImageSource ? 'Vision OCR (Gemma 4)...' : 'Extracting PDF Text...';
      case 4:
        return 'Semantic Chunking...';
      case 5:
        return 'Generating AI Embeddings...';
      case 6:
        return 'Persisting to Vector Store...';
    }
    return 'Ready';
  }

  Future<void> _startIngestion() async {
    if (_isIngesting) return;

    final categoryName = _categoryController.text.trim();
    if (categoryName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a subject name first.')),
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null) return;

    // Find or create the category
    final categoryBox = _ragService.categoryBox;
    SubjectCategory? category = categoryBox
        .query(SubjectCategory_.name.equals(categoryName))
        .build()
        .findFirst();
    if (category == null) {
      category = SubjectCategory(name: categoryName);
      categoryBox.put(category);
    }

    setState(() {
      _isIngesting = true;
      _isImageSource = false;
      _step = 0;
      _progress = 0;
      _status = 'Starting...';
      _pageCurrent = 0;
      _pageTotal = 0;
      _chunkCurrent = 0;
      _chunkTotal = 0;
    });

    try {
      await _ragService.ingestDocument(
        file: result.files.first,
        category: category,
        onStep: (step, subStep) {
          if (mounted) {
            setState(() {
              _step = step;
              _status = _labelForStep(step);
              // Coarse progress from step phase. Phase B (embedding) is
              // refined by onChunkProgress below.
              _progress = (step - 1) / 6.0 + (subStep / 600.0);
            });
          }
        },
        onPageProgress: (page, total) {
          if (mounted) {
            setState(() {
              _pageCurrent = page;
              _pageTotal = total;
            });
          }
        },
        onChunkProgress: (chunk, total) {
          if (mounted) {
            setState(() {
              _chunkCurrent = chunk;
              _chunkTotal = total;
              // Phase B covers steps 5-6 of the 6-step pipeline. Map
              // chunk progress to the back half of the bar so the user
              // sees real movement during the long embedding stage.
              if (total > 0) {
                _progress = (4 / 6.0) + (chunk / total) * (2 / 6.0);
              }
            });
          }
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Ingestion complete! "${result.files.first.name}" added to $categoryName.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isIngesting = false;
          _status = 'Finished';
          _progress = 1.0;
        });
      }
    }
  }

  Future<void> _startImageIngestion() async {
    if (_isIngesting) return;

    final categoryName = _categoryController.text.trim();
    if (categoryName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a subject name first.')),
      );
      return;
    }

    if (!FlutterGemma.hasActiveModel()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gemma 4 is not ready yet. Wait for "System Ready" then try again.'),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result == null) return;

    final categoryBox = _ragService.categoryBox;
    SubjectCategory? category = categoryBox
        .query(SubjectCategory_.name.equals(categoryName))
        .build()
        .findFirst();
    if (category == null) {
      category = SubjectCategory(name: categoryName);
      categoryBox.put(category);
    }

    setState(() {
      _isIngesting = true;
      _isImageSource = true;
      _step = 0;
      _progress = 0;
      _status = 'Starting...';
    });

    try {
      await _ragService.ingestImage(
        file: result.files.first,
        category: category,
        onStep: (step, subStep) {
          if (mounted) {
            setState(() {
              _step = step;
              _status = _labelForStep(step);
              _progress = (step - 1) / 6.0 + (subStep / 600.0);
            });
          }
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Ingestion complete! "${result.files.first.name}" added to $categoryName.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isIngesting = false;
          _status = 'Finished';
          _progress = 1.0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Hero area ──────────────────────────────────────────────
          const SizedBox(height: 16),
          const Icon(Icons.auto_awesome, size: 72, color: Color(0xFFB388FF)),
          const SizedBox(height: 20),
          const Text(
            'Knowledge Ingestion',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isIngesting ? _status : 'Add new documents to your AI knowledge base',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 16),

          // ── Status pill ────────────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: GlassTheme.panel(radius: 14),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _systemStatus == 'System Ready'
                            ? GlassTheme.success
                            : const Color(0xFFB388FF),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Status: $_systemStatus',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Subject field ──────────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                decoration: GlassTheme.panel(radius: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Subject',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _categoryController,
                      enabled: !_isIngesting,
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Color(0xFFB388FF),
                      decoration: InputDecoration(
                        labelText: 'Category Name',
                        hintText: 'e.g. Serverless, Generative AI…',
                        labelStyle: TextStyle(
                            color: Colors.white.withOpacity(0.7)),
                        hintStyle: TextStyle(
                            color: Colors.white.withOpacity(0.35)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.06),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 14),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                              color: Colors.white.withOpacity(0.18)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(
                              color: Color(0xFFB388FF), width: 1.4),
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                              color: Colors.white.withOpacity(0.08)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ── Progress / Button ──────────────────────────────────────
          if (_isIngesting) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 10,
                backgroundColor: Colors.white.withOpacity(0.10),
                valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFFB388FF)),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                '${(_progress * 100).toInt()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            if (_pageTotal > 0 || _chunkTotal > 0) ...[
              const SizedBox(height: 8),
              Center(
                child: Column(
                  children: [
                    if (_pageTotal > 0)
                      Text(
                        'Page $_pageCurrent of $_pageTotal',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    if (_chunkTotal > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Embedded $_chunkCurrent of $_chunkTotal chunks',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.65),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ] else
            Row(
              children: [
                Expanded(child: _ingestButton(
                  label: 'PDF Document',
                  icon: Icons.picture_as_pdf_rounded,
                  onTap: _startIngestion,
                )),
                const SizedBox(width: 12),
                Expanded(child: _ingestButton(
                  label: 'Image / Snapshot',
                  icon: Icons.image_rounded,
                  onTap: _startImageIngestion,
                )),
              ],
            ),

          const SizedBox(height: 32),

          // ── Pipeline steps ─────────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                decoration: GlassTheme.panel(radius: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pipeline',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _buildStepInfo(1, 'Source Extraction'),
                    _buildStepInfo(2, 'Context Chunking'),
                    _buildStepInfo(3, 'Vector Embedding'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ingestButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFB388FF), Color(0xFF9B59F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF9B59F5).withOpacity(0.40),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 22),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      letterSpacing: 0.1,
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

  Widget _buildStepInfo(int stepNum, String title) {
    final bool isCompleted = _step > (stepNum * 2);
    final bool isActive =
        _step >= (stepNum * 2 - 1) && _step <= (stepNum * 2);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            isCompleted
                ? Icons.check_circle_rounded
                : (isActive
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
            color: isCompleted
                ? GlassTheme.success
                : (isActive
                    ? const Color(0xFFB388FF)
                    : Colors.white.withOpacity(0.25)),
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: TextStyle(
              color: isActive
                  ? Colors.white
                  : Colors.white.withOpacity(0.55),
              fontWeight:
                  isActive ? FontWeight.w700 : FontWeight.normal,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
