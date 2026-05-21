import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'widgets/glass_theme.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'objectbox.g.dart';
import 'models/entities.dart';
import 'services/rag_service.dart';
import 'models/embedding_model.dart' as example_embedding_model;
import 'models/model.dart';
import 'widgets/glass_thinking_panel.dart';
import 'services/auth_token_service.dart';
import 'category_browser_screen.dart';
import 'chat_message.dart';
import 'main.dart';

class PdfRagScreen extends StatefulWidget {
  final String? preSelectedCategory;
  const PdfRagScreen({Key? key, this.preSelectedCategory}) : super(key: key);

  @override
  State<PdfRagScreen> createState() => _PdfRagScreenState();
}

class _PdfRagScreenState extends State<PdfRagScreen> {
  RagService? _ragService;
  
  final TextEditingController _subjectController = TextEditingController(text: 'Science');
  final TextEditingController _searchController = TextEditingController();
  
  bool _isIngesting = false;
  bool _isSearching = false;
  String _statusMessage = 'System Ready';
  double _ingestionProgress = 0.0;
  String? _debugOcrText;
  bool _isExtracting = false;
  
  List<Message> _messages = [];
  String? _currentStreamingText;

  // Gemma 4 reasoning channel — streams as ThinkingResponse alongside the
  // answer text. We accumulate it while the model is thinking, then attach
  // it to the bot's reply once the response message is added to _messages.
  String? _currentStreamingThinking;
  // Maps message index in `_messages` → captured thinking content for
  // that message. Only populated for bot responses that produced any.
  final Map<int, String> _thinkingByMessageIndex = {};

  @override
  void initState() {
    super.initState();
    if (widget.preSelectedCategory != null) {
      _subjectController.text = widget.preSelectedCategory!;
    }
    _ragService = RagService(objectBox.store);
    _checkModelActivation();
  }

  Future<void> _checkModelActivation() async {
    try {
      // Auto-activate an embedding model
      bool hasEmbedder = await FlutterGemma.hasActiveEmbedder();
      if (!hasEmbedder) {
        setState(() => _statusMessage = 'Activating embedder...');
        final token = await AuthTokenService.loadToken();
        final model = example_embedding_model.EmbeddingModel.gecko512;
        await FlutterGemma.installEmbedder()
          .modelFromNetwork(model.url, token: token)
          .tokenizerFromNetwork(model.tokenizerUrl, token: token, iosPath: model.iosTokenizerPath)
          .install();
        await FlutterGemma.getActiveEmbedder();
      }

      // Auto-activate Gemma 4 with vision support so image OCR works.
      if (!FlutterGemma.hasActiveModel()) {
        final gemma4 = Model.gemma4_E2B;
        if (await FlutterGemma.isModelInstalled(gemma4.filename)) {
          setState(() => _statusMessage = 'Activating Gemma 4...');
          await FlutterGemma.installModel(modelType: gemma4.modelType, fileType: gemma4.fileType).fromNetwork(gemma4.url).install();
          await FlutterGemma.getActiveModel(
            maxTokens: gemma4.maxTokens,
            supportImage: gemma4.supportImage,
            maxNumImages: gemma4.maxNumImages,
          );
        }
      }

      setState(() => _statusMessage = 'System Ready');
    } catch (e) {
      setState(() => _statusMessage = 'Init Error: $e');
    }
  }

  Future<SubjectCategory?> _resolveCategory() async {
    if (_ragService == null) return null;
    final categoryName = _subjectController.text.trim();
    if (categoryName.isEmpty) return null;
    final existing = _ragService!.categoryBox
        .query(SubjectCategory_.name.equals(categoryName))
        .build()
        .findFirst();
    final category = existing ?? SubjectCategory(name: categoryName);
    if (existing == null) _ragService!.categoryBox.put(category);
    return category;
  }

  Future<void> _pickAndIngestPdf() async {
    if (_ragService == null) return;

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null || result.files.single.path == null) return;

    final category = await _resolveCategory();
    if (category == null) return;

    setState(() {
      _isIngesting = true;
      _ingestionProgress = 0.0;
      _statusMessage = 'Ingesting ${result.files.single.name}...';
    });

    try {
      await _ragService!.ingestDocument(
        file: result.files.single,
        category: category,
        onProgress: (page, total) {
          setState(() {
            _ingestionProgress = page / total;
            _statusMessage = 'Processing page $page of $total (${(_ingestionProgress * 100).toInt()}%)...';
          });
        },
      );
      setState(() {
        _statusMessage = 'Ingestion complete!';
        _ingestionProgress = 0.0;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
        _ingestionProgress = 0.0;
      });
    } finally {
      setState(() => _isIngesting = false);
    }
  }

  Future<void> _pickAndExtractOnly() async {
    if (_ragService == null) return;
    if (!FlutterGemma.hasActiveModel()) {
      setState(() => _statusMessage = 'Gemma 4 not ready. Wait for System Ready.');
      return;
    }

    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.single.path == null) return;

    setState(() {
      _isExtracting = true;
      _debugOcrText = null;
      _statusMessage = 'Running Vision OCR on ${result.files.single.name}...';
    });

    try {
      final bytes = await File(result.files.single.path!).readAsBytes();
      final text = await _ragService!.extractTextFromImageBytes(bytes);
      setState(() {
        _debugOcrText = text.isEmpty ? '(empty — Gemma 4 returned no text)' : text;
        _statusMessage = 'OCR done — ${text.length} chars extracted.';
      });
    } catch (e) {
      setState(() {
        _debugOcrText = null;
        _statusMessage = 'OCR error: $e';
      });
    } finally {
      setState(() => _isExtracting = false);
    }
  }

  Future<void> _pickAndIngestImage() async {
    if (_ragService == null) return;

    if (!FlutterGemma.hasActiveModel()) {
      setState(() => _statusMessage = 'Gemma 4 not ready. Wait for System Ready.');
      return;
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result == null || result.files.single.path == null) return;

    final category = await _resolveCategory();
    if (category == null) return;

    setState(() {
      _isIngesting = true;
      _ingestionProgress = 0.0;
      _statusMessage = 'Running Vision OCR on ${result.files.single.name}...';
    });

    try {
      final chunkCount = await _ragService!.ingestImage(
        file: result.files.single,
        category: category,
        onStep: (step, subStep) {
          final labels = {
            1: 'Saving image...',
            2: 'Registering metadata...',
            3: 'Vision OCR (Gemma 4)...',
            4: 'Semantic chunking...',
            5: 'Generating embeddings...',
            6: 'Persisting to vector store...',
          };
          setState(() {
            _ingestionProgress = (step - 1) / 6.0 + (subStep / 600.0);
            _statusMessage = labels[step] ?? 'Processing...';
          });
        },
      );
      setState(() {
        _statusMessage = 'Ingestion complete — $chunkCount chunks stored.';
        _ingestionProgress = 0.0;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
        _ingestionProgress = 0.0;
      });
    } finally {
      setState(() => _isIngesting = false);
    }
  }

  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _searchController.dispose();
    _subjectController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (_ragService == null || query.isEmpty) {
      debugPrint('Search cancelled: RagService is null or query is empty');
      return;
    }
    
    setState(() {
      _isSearching = true;
      _statusMessage = 'Searching category: ${_subjectController.text}...';
      _messages.add(Message.text(text: query, isUser: true));
      _currentStreamingText = '';
      _currentStreamingThinking = null;
      _searchController.clear();
    });

    try {
      final categoryName = _subjectController.text.trim();
      debugPrint('Step 1: Finding category "$categoryName"');
      final category = _ragService!.categoryBox.query(SubjectCategory_.name.equals(categoryName)).build().findFirst();
      
      if (category == null) {
        debugPrint('Step 1 Failure: Category not found');
        setState(() => _statusMessage = 'Category "$categoryName" not found. Please ingest a PDF first.');
        return;
      }

      debugPrint('Step 2: Vector search for "$query" in category ID ${category.id}');
      final results = await _ragService!.searchByCategory(query, category.id);
      debugPrint('Step 2 Result: Found ${results.length} relevant chunks');

      setState(() {
        _statusMessage = results.isEmpty ? 'No relevant info found' : 'Generating educational answer...';
      });

      if (results.isNotEmpty) {
        debugPrint('Step 3: Generating answer stream');
        final stream = await _ragService!.generateAnswerStream(query, results);
        await for (final response in stream) {
          if (!mounted) break;

          if (response is TextResponse) {
            setState(() {
              _currentStreamingText = (_currentStreamingText ?? '') + response.token;
            });
            _scrollToBottom();
          } else if (response is ThinkingResponse) {
            // Gemma 4 reasoning channel — accumulate so we can display it
            // in the GlassThinkingPanel above the eventual answer bubble.
            setState(() {
              _currentStreamingThinking =
                  (_currentStreamingThinking ?? '') + response.content;
            });
            _scrollToBottom();
          } else if (response is FunctionCallResponse) {
            debugPrint('Step 4: Tool Call Intercepted: ${response.name}');
            setState(() {
              _messages.add(Message.systemInfo(
                text: "🔧 Calling: ${response.name}(${response.args}) TOOL_DATA:${response.args}",
              ));
            });
            _scrollToBottom();
          }
        }

        if (_currentStreamingText != null && _currentStreamingText!.isNotEmpty) {
          setState(() {
            _messages.add(Message.text(text: _currentStreamingText!));
            // Attach the captured reasoning (if any) to this new message.
            final newIndex = _messages.length - 1;
            final thinking = _currentStreamingThinking;
            if (thinking != null && thinking.trim().isNotEmpty) {
              _thinkingByMessageIndex[newIndex] = thinking;
            }
            _currentStreamingText = null;
            _currentStreamingThinking = null;
          });
        }
        debugPrint('Search workflow completed successfully');
        setState(() => _statusMessage = 'Search complete');
      }
    } catch (e) {
      debugPrint('Search Workflow ERROR: $e');
      setState(() => _statusMessage = 'Search Error: $e');
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
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
                title: const Text(
                  'Offline Category RAG',
                  style: TextStyle(
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
                      message: 'View Library',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            if (_ragService != null) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) =>
                                        CategoryBrowserScreen(
                                            ragService: _ragService!)),
                              ).then((_) => setState(() {}));
                            }
                          },
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
                              child: Icon(Icons.library_books,
                                  color: Colors.white, size: 20),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
        body: SingleChildScrollView(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.of(context).padding.top + kToolbarHeight + 12,
            16,
            MediaQuery.of(context).padding.bottom + 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildStatusPill(),
              const SizedBox(height: 16),
              _buildGlassSection(
                title: '1. Subject Management',
                children: [
                  _buildGlassTextField(
                    controller: _subjectController,
                    label: 'Category Name',
                    hint: 'Cloud, Cybersecurity, etc.',
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _buildPrimaryButton(
                          icon: Icons.picture_as_pdf,
                          label: 'PDF Document',
                          accent: const Color(0xFFB388FF),
                          onTap: _isIngesting ? null : _pickAndIngestPdf,
                          busy: _isIngesting,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildPrimaryButton(
                          icon: Icons.image_rounded,
                          label: 'Image',
                          accent: const Color(0xFFB388FF),
                          onTap: _isIngesting ? null : _pickAndIngestImage,
                          busy: false,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPrimaryButton(
                    icon: Icons.visibility_rounded,
                    label: 'Test OCR Only (debug)',
                    accent: const Color(0xFFFFB74D),
                    onTap: (_isIngesting || _isExtracting) ? null : _pickAndExtractOnly,
                    busy: _isExtracting,
                  ),
                  if (_debugOcrText != null) ...[
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: GlassTheme.panel(radius: 14),
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.text_snippet_rounded,
                                      color: Color(0xFFFFB74D), size: 16),
                                  const SizedBox(width: 8),
                                  Text(
                                    'OCR result (${_debugOcrText!.length} chars)',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    iconSize: 18,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(Icons.close,
                                        color: Colors.white70),
                                    onPressed: () =>
                                        setState(() => _debugOcrText = null),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    _debugOcrText!,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.92),
                                      fontSize: 13,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (_isIngesting) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: _ingestionProgress,
                        backgroundColor: Colors.white.withOpacity(0.10),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFFB388FF)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        '${(_ingestionProgress * 100).toInt()}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.8),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              _buildGlassSection(
                title: '2. Contextual Search',
                children: [
                  _buildGlassTextField(
                    controller: _searchController,
                    label: 'Query',
                    hint: 'Ask about this category...',
                    onSubmitted: (_) => _search(),
                  ),
                  const SizedBox(height: 14),
                  _buildPrimaryButton(
                    icon: Icons.search,
                    label: 'Search Category',
                    accent: const Color(0xFF82B1FF),
                    onTap: _isSearching ? null : _search,
                    busy: _isSearching,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Interleave thinking panels before any bot replies that
              // captured reasoning, so the user can expand them inline.
              for (int i = 0; i < _messages.length; i++) ...[
                if (_thinkingByMessageIndex[i] != null)
                  GlassThinkingPanel(
                    content: _thinkingByMessageIndex[i]!,
                    isStreaming: false,
                  ),
                ChatMessageWidget(message: _messages[i]),
              ],
              // Live thinking panel while the model is reasoning. Shown
              // ABOVE any text that's already streaming.
              if (_isSearching &&
                  _currentStreamingThinking != null &&
                  _currentStreamingThinking!.trim().isNotEmpty)
                GlassThinkingPanel(
                  content: _currentStreamingThinking!,
                  isStreaming: true,
                ),
              if (_currentStreamingText != null &&
                  _currentStreamingText!.isNotEmpty)
                ChatMessageWidget(
                    message: Message.text(text: _currentStreamingText!)),
              if (_isSearching &&
                  (_currentStreamingText == null ||
                      _currentStreamingText!.isEmpty) &&
                  (_currentStreamingThinking == null ||
                      _currentStreamingThinking!.isEmpty))
                _buildThinkingPill(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill() {
    return ClipRRect(
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
                decoration: const BoxDecoration(
                  color: Color(0xFF82B1FF),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Status: $_statusMessage',
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
    );
  }

  Widget _buildGlassSection({
    required String title,
    required List<Widget> children,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: GlassTheme.panel(radius: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlassTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    void Function(String)? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white),
      cursorColor: const Color(0xFF82B1FF),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
        filled: true,
        fillColor: Colors.white.withOpacity(0.06),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.18)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF82B1FF), width: 1.4),
        ),
      ),
    );
  }

  Widget _buildPrimaryButton({
    required IconData icon,
    required String label,
    required Color accent,
    required VoidCallback? onTap,
    bool busy = false,
  }) {
    final disabled = onTap == null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
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
                color: accent.withOpacity(disabled ? 0.30 : 0.55),
              ),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(accent),
                      ),
                    )
                  else
                    Icon(icon, color: accent, size: 18),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(disabled ? 0.6 : 0.95),
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        letterSpacing: 0.2,
                      ),
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

  Widget _buildThinkingPill() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF82B1FF).withOpacity(0.15),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: const Color(0xFF82B1FF).withOpacity(0.45)),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF82B1FF)),
                ),
              ),
              SizedBox(width: 14),
              Text('AI is thinking...',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}
