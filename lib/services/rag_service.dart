import 'dart:io';
import 'package:educloud/models/embedding_model.dart' as local_models;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:langchain/langchain.dart';
import 'package:objectbox/objectbox.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model_response.dart';
import 'package:path/path.dart' as p;

import '../objectbox.g.dart';
import '../models/entities.dart';
import 'educational_tool_service.dart';

class RagService {
  final Store _store;
  late final Box<SubjectCategory> _categoryBox;
  late final Box<StudyDocument> _documentBox;
  late final Box<VectorChunk> _chunkBox;

  RagService(this._store) {
    _categoryBox = _store.box<SubjectCategory>();
    _documentBox = _store.box<StudyDocument>();
    _chunkBox = _store.box<VectorChunk>();
  }

  /// Step 2: The Physical File Storage Service
  Future<String> savePdfToDevice(PlatformFile file, SubjectCategory category) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    
    // Create category-specific subdirectory
    final categoryDir = Directory(p.join(appDocDir.path, category.name));
    if (!await categoryDir.exists()) {
      await categoryDir.create(recursive: true);
    }

    final targetPath = p.join(categoryDir.path, file.name);
    final sourceFile = File(file.path!);
    
    await sourceFile.copy(targetPath);
    print("PDF saved physically to: $targetPath");
    return targetPath;
  }

  Future<String> saveImageToDevice(PlatformFile file, SubjectCategory category) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final categoryDir = Directory(p.join(appDocDir.path, category.name));
    if (!await categoryDir.exists()) {
      await categoryDir.create(recursive: true);
    }
    final targetPath = p.join(categoryDir.path, file.name);
    await File(file.path!).copy(targetPath);
    return targetPath;
  }

  /// Public wrapper for the OCR step — useful for debugging the vision pipeline
  /// in isolation, without running chunking / embedding / storage.
  Future<String> extractTextFromImageBytes(Uint8List imageBytes) =>
      _extractTextFromImage(imageBytes);

  Future<String> _extractTextFromImage(Uint8List imageBytes) async {
    if (!FlutterGemma.hasActiveModel()) {
      throw StateError('No active inference model. Load Gemma 4 first.');
    }
    print('OCR: starting Gemma 4 vision on ${imageBytes.length} bytes');
    final model = await FlutterGemma.getActiveModel(
      maxTokens: 2048,
      supportImage: true,
      maxNumImages: 1,
    );
    final chat = await model.createChat(
      temperature: 0.1,
      supportImage: true,
    );
    try {
      await chat.addQuery(Message.withImage(
        text: 'Transcribe all text visible in this image. '
            'Preserve structure: headings, bullet points, numbered lists, and equations. '
            'Output only the transcribed text with no commentary.',
        imageBytes: imageBytes,
        isUser: true,
      ));
      final buffer = StringBuffer();
      await for (final token in chat.generateChatResponseAsync()) {
        if (token is TextResponse) buffer.write(token.token);
      }
      final result = buffer.toString();
      print('OCR: extracted ${result.length} chars. Preview: '
          '"${result.length > 200 ? '${result.substring(0, 200)}...' : result}"');
      return result;
    } finally {
      await chat.close();
    }
  }

  Future<int> ingestImage({
    required PlatformFile file,
    required SubjectCategory category,
    Function(int step, int subStep)? onStep,
    int embedBatchSize = 32,
  }) async {
    final stopwatch = Stopwatch()..start();

    onStep?.call(1, 1);
    final String localPath = await saveImageToDevice(file, category);
    onStep?.call(1, 2);

    onStep?.call(2, 1);
    final documentEntity = StudyDocument(
      title: file.name,
      localFilePath: localPath,
      uploadTimestamp: DateTime.now(),
    );
    documentEntity.category.target = category;
    _documentBox.put(documentEntity);
    onStep?.call(2, 2);

    // Verify embedder is available before starting OCR.
    if (!FlutterGemma.hasActiveEmbedder()) {
      throw StateError('No active embedding model set.');
    }

    onStep?.call(3, 1);
    final imageBytes = await File(localPath).readAsBytes();
    final extractedText = await _extractTextFromImage(imageBytes);
    onStep?.call(3, 2);

    if (extractedText.trim().isEmpty) {
      throw StateError('Gemma 4 returned no text from the image. The image may be unreadable or vision OCR failed.');
    }

    onStep?.call(4, 1);
    final textSplitter = RecursiveCharacterTextSplitter(
      chunkSize: 400,
      chunkOverlap: 50,
    );
    final pendingTexts = textSplitter
        .createDocuments([extractedText])
        .map((d) => d.pageContent.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    onStep?.call(4, 2);

    print('Ingestion: extracted ${pendingTexts.length} chunks from image '
        'in ${stopwatch.elapsedMilliseconds}ms');

    if (pendingTexts.isEmpty) {
      throw StateError('Extracted text was non-empty but produced no chunks after splitting.');
    }

    onStep?.call(5, 1);
    // Re-acquire embedder after OCR — the inference session may have
    // invalidated the previously held handle.
    final embeddingModel = await FlutterGemma.getActiveEmbedder();
    final List<VectorChunk> chunksToInsert = [];
    for (final text in pendingTexts) {
      try {
        final emb = await embeddingModel
            .generateEmbedding(text, taskType: TaskType.retrievalDocument)
            .timeout(const Duration(seconds: 30));
        if (emb.isEmpty) continue;
        final chunk = VectorChunk(
          text: text,
          pageNumber: 1,
          embedding: Float32List.fromList(emb),
        );
        chunk.document.target = documentEntity;
        chunk.category.target = category;
        chunksToInsert.add(chunk);
      } catch (e) {
        print('Embed failed for chunk: $e');
      }
    }
    print('Image ingestion: embedded ${chunksToInsert.length}/${pendingTexts.length} chunks.');
    if (chunksToInsert.isEmpty) {
      throw StateError('Embedding failed for all chunks — no data stored.');
    }
    onStep?.call(5, 2);

    onStep?.call(6, 1);
    if (chunksToInsert.isNotEmpty) {
      _chunkBox.putMany(chunksToInsert);
    }
    onStep?.call(6, 2);

    stopwatch.stop();
    print('Image ingestion complete: ${chunksToInsert.length} chunks saved '
        'in ${stopwatch.elapsedMilliseconds}ms.');
    return chunksToInsert.length;
  }

  /// Step 3: The Complete Ingestion Pipeline (batched + parallelized)
  Future<void> ingestDocument({
    required PlatformFile file,
    required SubjectCategory category,
    Function(int page, int total)? onProgress,
    Function(int page, int total)? onPageProgress,
    Function(int chunk, int total)? onChunkProgress,
    Function(int step, int subStep)? onStep,
    int embedBatchSize = 32,
    int minChunkChars = 20,
  }) async {
    final stopwatch = Stopwatch()..start();

    // Step 1: Physical storage
    onStep?.call(1, 1);
    final String localPath = await savePdfToDevice(file, category);
    onStep?.call(1, 2);

    // Step 2: Create StudyDocument entity
    onStep?.call(2, 1);
    final documentEntity = StudyDocument(
      title: file.name,
      localFilePath: localPath,
      uploadTimestamp: DateTime.now(),
    );
    documentEntity.category.target = category;
    _documentBox.put(documentEntity);
    onStep?.call(2, 2);

    // Step 3: Open PDF
    onStep?.call(3, 1);
    final bytes = await File(localPath).readAsBytes();
    final PdfDocument pdfDoc = PdfDocument(inputBytes: bytes);
    final PdfTextExtractor extractor = PdfTextExtractor(pdfDoc);
    final int pageCount = pdfDoc.pages.count;
    onStep?.call(3, 2);

    // Step 4: Chunker (created once, reused)
    onStep?.call(4, 1);
    final textSplitter = RecursiveCharacterTextSplitter(
      chunkSize: 400,
      chunkOverlap: 50,
    );
    onStep?.call(4, 2);

    // Step 5: Activate embedder once
    onStep?.call(5, 1);
    final bool hasEmbedder = await FlutterGemma.hasActiveEmbedder();
    if (!hasEmbedder) {
      pdfDoc.dispose();
      throw StateError('No active embedding model set.');
    }
    final embeddingModel = await FlutterGemma.getActiveEmbedder();
    onStep?.call(5, 2);

    // Phase A: extract + chunk every page into a flat (text, pageNumber) list.
    // This is fast (no embedding work) so we can do it in one pass and free the
    // PDF handle before we start the (slower) embedding work.
    final List<String> pendingTexts = [];
    final List<int> pendingPages = [];

    for (int i = 0; i < pageCount; i++) {
      final int pageNumber = i + 1;
      onProgress?.call(pageNumber, pageCount);
      onPageProgress?.call(pageNumber, pageCount);

      final String pageText =
          extractor.extractText(startPageIndex: i, endPageIndex: i);
      if (pageText.trim().isEmpty) continue;

      final List<Document> splitDocs =
          textSplitter.createDocuments([pageText]);
      for (final d in splitDocs) {
        final t = d.pageContent.trim();
        // Drop tiny chunks — they cost just as much to embed but rarely
        // produce useful semantic matches.
        if (t.length < minChunkChars) continue;
        pendingTexts.add(t);
        pendingPages.add(pageNumber);
      }

      // Yield once per page so the UI thread can paint progress updates
      // during the (CPU-bound) text extraction loop.
      await Future.delayed(Duration.zero);
    }

    pdfDoc.dispose();
    print('Ingestion: extracted ${pendingTexts.length} chunks from '
        '$pageCount pages in ${stopwatch.elapsedMilliseconds}ms');

    if (pendingTexts.isEmpty) {
      print('Ingestion: nothing to embed.');
      onStep?.call(6, 2);
      return;
    }

    // Phase B: batch-embed. ONE call per batch instead of one per chunk.
    // Gecko/MobileBert variants accept generateEmbeddings(List<String>) which
    // is dramatically faster than calling generateEmbedding() per chunk.
    final List<VectorChunk> chunksToInsert = [];
    final int total = pendingTexts.length;

    // Surface the total chunk count as soon as we know it so the UI can
    // render "0 of 412 chunks" immediately instead of "0 of unknown".
    onChunkProgress?.call(0, total);

    for (int start = 0; start < total; start += embedBatchSize) {
      final int end =
          (start + embedBatchSize < total) ? start + embedBatchSize : total;
      final batchTexts = pendingTexts.sublist(start, end);
      final batchPages = pendingPages.sublist(start, end);

      List<List<double>> batchEmbeddings;
      try {
        batchEmbeddings = await embeddingModel
            .generateEmbeddings(batchTexts,
                taskType: TaskType.retrievalDocument)
            .timeout(const Duration(seconds: 60));
      } catch (e) {
        // Fallback: if the active embedder doesn't support batch, embed one
        // by one. Still avoids the old artificial delay.
        print('Batch embed failed ($e), falling back to per-chunk.');
        batchEmbeddings = [];
        for (final t in batchTexts) {
          try {
            final v = await embeddingModel
                .generateEmbedding(t, taskType: TaskType.retrievalDocument)
                .timeout(const Duration(seconds: 15));
            batchEmbeddings.add(v);
          } catch (e) {
            print('Per-chunk embed failed: $e');
            batchEmbeddings.add(const []);
          }
        }
      }

      for (int k = 0; k < batchTexts.length; k++) {
        final emb = batchEmbeddings[k];
        if (emb.isEmpty) continue;
        final chunk = VectorChunk(
          text: batchTexts[k],
          pageNumber: batchPages[k],
          embedding: Float32List.fromList(emb),
        );
        chunk.document.target = documentEntity;
        chunk.category.target = category;
        chunksToInsert.add(chunk);
      }

      // Repurpose the page-progress callback so the UI keeps moving while we
      // embed (otherwise it would freeze at 100% during phase B).
      onProgress?.call(end, total);
      onChunkProgress?.call(end, total);
    }

    // Step 6: Single batched vector write
    onStep?.call(6, 1);
    if (chunksToInsert.isNotEmpty) {
      _chunkBox.putMany(chunksToInsert);
    }
    onStep?.call(6, 2);

    stopwatch.stop();
    print('Ingestion complete: ${chunksToInsert.length} chunks saved '
        'in ${stopwatch.elapsedMilliseconds}ms '
        '(${(stopwatch.elapsedMilliseconds / chunksToInsert.length).toStringAsFixed(1)}ms/chunk).');
  }

  /// Search for chunks filtered by category
  Future<List<VectorChunk>> searchByCategory(
    String query, 
    int categoryId, {
    int maxResults = 5,
  }) async {
    // ENSURE EMBEDDER IS ACTIVE
    try {
      await FlutterGemma.getActiveEmbedder();
    } catch (_) {
      print("RagService: No active embedder. Activating Gecko 512...");
      final model = local_models.EmbeddingModel.gecko512;
      await FlutterGemma.installEmbedder()
          .modelFromNetwork(model.url)
          .tokenizerFromNetwork(model.tokenizerUrl, iosPath: model.iosTokenizerPath)
          .install();
    }

    final embeddingModel = await FlutterGemma.getActiveEmbedder();
    final List<double> queryEmbeddingList = await embeddingModel
        .generateEmbedding(query, taskType: TaskType.retrievalQuery);
    final Float32List queryEmbedding = Float32List.fromList(queryEmbeddingList);

    final dbQuery = _chunkBox.query(
      VectorChunk_.embedding.nearestNeighborsF32(queryEmbedding, maxResults)
      .and(VectorChunk_.category.equals(categoryId))
    ).build();

    final List<ObjectWithScore<VectorChunk>> results = dbQuery.findWithScores();
    dbQuery.close();

    return results.map((result) => result.object).toList();
  }

  /// Generate answer from chunks using interactive tools
  Future<Stream<ModelResponse>> generateAnswerStream(String query, List<VectorChunk> contextChunks) async {
    if (contextChunks.isEmpty) {
      return Stream.value(TextResponse("No relevant info found in the category."));
    }

    final String context = contextChunks.map((c) => "[Page ${c.pageNumber}]: ${c.text}").join("\n\n");
    
    final String prompt = """SYSTEM: You are an expert educational tutor. 
You have access to interactive tools like quizzes, badges, and timers.
Use the following context to help the student. 
If the student wants a quiz, use generate_interactive_quiz.
If they master a concept, use award_badge.

Context:
$context

User Question: $query""";

    final chat = await EducationalToolService.createEducationalChat();
    await chat.addQuery(Message.text(text: prompt));
    return chat.generateChatResponseAsync();
  }

  Box<SubjectCategory> get categoryBox => _categoryBox;
  Box<StudyDocument> get documentBox => _documentBox;
  Store get store => _store;

  /// Retrieve all available categories
  List<SubjectCategory> getAllCategories() {
    return _categoryBox.getAll();
  }

  /// Retrieve all documents for a specific category
  List<StudyDocument> getDocumentsForCategory(int categoryId) {
    return _documentBox.query(StudyDocument_.category.equals(categoryId)).build().find();
  }

  /// Wipe all data for testing
  Future<void> clearAllData() async {
    _chunkBox.removeAll();
    _documentBox.removeAll();
    _categoryBox.removeAll();
    
    // Also clean up physical files
    final appDocDir = await getApplicationDocumentsDirectory();
    final contents = await appDocDir.list().toList();
    for (var item in contents) {
      if (item is Directory && !p.basename(item.path).contains('objectbox')) {
        await item.delete(recursive: true);
      }
    }
    print("All local data and files erased.");
  }
}
