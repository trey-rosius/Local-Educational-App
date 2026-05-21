import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:objectbox/objectbox.dart';
import '../services/memory_guard.dart';
import '../services/notification_service.dart';
import '../services/educational_tool_service.dart';
import '../models/entities.dart';
import 'rag_service.dart';
import '../objectbox.g.dart';
import '../models/model.dart';
import '../utils/json_utils.dart';
import '../main.dart';

/// User-selectable workshop depth.
enum WorkshopDepth {
  beginner('Beginner'),
  intermediate('Intermediate'),
  advanced('Advanced');

  const WorkshopDepth(this.label);
  final String label;

  String get promptGuidance {
    switch (this) {
      case WorkshopDepth.beginner:
        return 'Assume the student has no prior knowledge of the topic. '
            'Use plain language, define every new term, include simple '
            'analogies, and progress slowly from fundamentals.';
      case WorkshopDepth.intermediate:
        return 'Assume the student knows the basics. Cover the topic in '
            'real depth, include concrete examples and trade-offs, and '
            'connect concepts across lessons.';
      case WorkshopDepth.advanced:
        return 'Assume strong fundamentals. Focus on advanced techniques, '
            'edge cases, performance/security implications, and how the '
            'concepts apply in production systems.';
    }
  }
}

/// User-selectable quiz difficulty.
enum QuizDifficulty {
  easy('Easy'),
  medium('Medium'),
  hard('Hard');

  const QuizDifficulty(this.label);
  final String label;

  /// Prompt fragment describing what kind of questions to generate.
  String get promptGuidance {
    switch (this) {
      case QuizDifficulty.easy:
        return 'Questions should test basic recall of facts that are '
            'explicitly stated in the context. Use clear, simple wording '
            'and short answer choices. Avoid trick questions.';
      case QuizDifficulty.medium:
        return 'Questions should test comprehension and the ability to '
            'apply concepts from the context to slightly different '
            'situations. Mix recall and reasoning. Distractor options '
            'should be plausible but clearly wrong on careful reading.';
      case QuizDifficulty.hard:
        return 'Questions should test analysis, synthesis, and inference. '
            'Require the student to combine multiple pieces of context '
            'or reason about implications that are not stated verbatim. '
            'Distractors should be subtle and require careful reading '
            'to eliminate.';
    }
  }
}

class StudyMaterialService {
  final RagService _ragService;
  late final Box<GeneratedStudyMaterial> _materialBox;

  StudyMaterialService(this._ragService, Store store) {
    _materialBox = store.box<GeneratedStudyMaterial>();
  }

  Future<void> _ensureModelActive() async {
    if (!FlutterGemma.hasActiveModel()) {
      final gemma4 = Model.gemma4_E2B;
      if (await FlutterGemma.isModelInstalled(gemma4.filename)) {
        await FlutterGemma.installModel(
          modelType: gemma4.modelType,
          fileType: gemma4.fileType,
        ).fromNetwork(gemma4.url).install();
      }
    }
  }

  Future<String> buildPrompt({
    required SubjectCategory category,
    required String type,
    int count = 10,
    QuizDifficulty difficulty = QuizDifficulty.medium,
  }) async {
    // Tool-call types (quiz, flashcards) need headroom for the schema +
    // structured response, so we pull fewer RAG chunks to keep the prompt
    // small. MemoryGuard further tightens these on lean (6 GB) devices.
    final bool isToolCallType = type == 'quiz' || type == 'flashcards';
    final ragChunks = MemoryGuard.instance
        .ragChunksForGeneration(count: count, toolCall: isToolCallType);
    final chunks = await _ragService.searchByCategory(
      "General overview of ${category.name}",
      category.id,
      maxResults: ragChunks,
    );

    final context = MemoryGuard.instance
        .capContext(chunks.map((c) => c.text).join("\n\n"));
    if (context.trim().isEmpty) {
      throw 'I couldn\'t find any information about "${category.name}" in your library.';
    }

    // NOTE: Quiz and flashcards prompts target the create_quiz / create_flashcards
    // TOOLS — structure is enforced by the schema, so this prompt focuses on
    // CONTENT guidance only. Do not re-add JSON-formatting rules here; they
    // conflict with "call this function" and degrade tool-call compliance.
    if (type == 'quiz') {
      return """Create a $count-question multiple-choice quiz for a student studying using the source material below.

Difficulty: ${difficulty.label}.
${difficulty.promptGuidance}

Content rules for each question:
- Test understanding of a distinct concept (do not repeat ideas across questions).
- Provide exactly 4 short, plain-English options — one sentence max.
- Options must NEVER be raw citations, bibliography entries, author lists, DOIs, URLs, or page-range markers from the source.
- Vary which option is correct across questions (do not always pick index 0).
- Provide a one-sentence explanation for the correct answer.

Call the create_quiz tool with the questions.

Source material:
$context""";
    } else if (type == 'mind_map') {
      return """Using the following context, extract key concepts for a Mind Map.
Return ONLY JSON with 'nodes' and 'edges'.
Context: $context""";
    } else if (type == 'summary') {
      return "Using the following context, generate a comprehensive study summary. Context: $context";
    } else if (type == 'flashcards') {
      return """Create $count flashcards from the source material below — each one a question-and-answer pair covering a distinct concept.

Content rules:
- Questions should be short and test one concept each.
- Answers should be 1-2 sentences max.
- Never include citations, bibliography text, page numbers, or raw quotes as questions or answers.

Call the create_flashcards tool with the cards.

Source material:
$context""";
    }
    return "";
  }

  Future<GeneratedStudyMaterial> saveMaterial({
    required SubjectCategory category,
    required String type,
    required String content,
    String? title,
  }) async {
    var repaired = _universalGemmaRepair(content, type);
    // For structured types, parse + validate. Drop garbage questions/cards
    // and re-encode. Throws on unfixable JSON so we never store a corpse
    // that surfaces as "Content Error" in the UI later.
    if (type == 'quiz') {
      repaired = _validateAndCleanQuiz(repaired);
    } else if (type == 'flashcards') {
      repaired = _validateAndCleanFlashcards(repaired);
    }

    final material = GeneratedStudyMaterial(
      type: type,
      title: title,
      contentJson: repaired,
      dateCreated: DateTime.now(),
    );
    material.category.target = category;
    _materialBox.put(material);
    return material;
  }

  Future<GeneratedStudyMaterial> generateAndSaveMaterial({
    required SubjectCategory category,
    required String type,
    int count = 10,
    QuizDifficulty difficulty = QuizDifficulty.medium,
  }) async {
    await _ensureModelActive();
    final prompt = await buildPrompt(category: category, type: type, count: count, difficulty: difficulty);
    final isolatedPrompt = "IMPORTANT: Focus ONLY on this new request. Ignore any previous context.\n\n$prompt";

    final model =
        await FlutterGemma.getActiveModel(maxTokens: MemoryGuard.instance.maxTokens);
    final chat = await model.createChat(temperature: 0.1);
    String rawText = "";
    try {
      await chat.addQuery(Message.text(text: isolatedPrompt));
      final response = await chat.generateChatResponse();
      if (response is TextResponse) rawText = response.token;
    } finally {
      // Close the CHAT to release KV cache. Do NOT close the model — it's a
      // process-wide singleton, and closing it leaves `getActiveModel()`
      // handing back a dangling pointer that the next inference will
      // double-free (crash: "pointer being freed was not allocated").
      await chat.close();
    }

    String? autoTitle;
    if (type == 'quiz') autoTitle = '${category.name} · ${difficulty.label} · $count Q';
    else if (type == 'flashcards') autoTitle = '${category.name} · $count cards';

    return saveMaterial(category: category, type: type, content: rawText, title: autoTitle);
  }

  /// Universal repair pipeline for model JSON output. Tries hard to coerce
  /// the on-device model's malformed JSON into something `jsonDecode` can
  /// parse. The downstream validator drops semantically-garbage content.
  String _universalGemmaRepair(String raw, String type) {
    if (type == 'summary') {
      return raw.replaceAll('```markdown', '').replaceAll('```', '').trim();
    }

    // 1. Atomic extraction — slice from the first `{`/`[` to the last
    //    `}`/`]` to strip away any prose/markdown the model wrapped around
    //    the JSON.
    final startBrace = raw.indexOf('{');
    final startBracket = raw.indexOf('[');
    int start;
    if (startBrace == -1) {
      start = startBracket;
    } else if (startBracket == -1) {
      start = startBrace;
    } else {
      start = startBrace < startBracket ? startBrace : startBracket;
    }
    if (start == -1) return raw.trim();
    final endBrace = raw.lastIndexOf('}');
    final endBracket = raw.lastIndexOf(']');
    int end = endBrace > endBracket ? endBrace : endBracket;
    if (end <= start) end = raw.length - 1;
    String s = raw.substring(start, end + 1);

    // 2. Normalize smart quotes.
    s = s
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('‘', "'")
        .replaceAll('’', "'");

    // 3. Strip stray `\"` escapes the model emits OUTSIDE of strings —
    //    we've seen [\"foo\", \"bar\"] over-escaping in real output.
    //    Protect `\\` with a sentinel so escaped backslashes aren't lost.
    const slashSentinel = '';
    s = s.replaceAll(r'\\', slashSentinel);
    s = s.replaceAll(r'\"', '"');
    s = s.replaceAll(slashSentinel, r'\\');

    // ORDER MATTERS for the next several passes — the state-aware ones
    // need quote symmetry first so they can correctly identify string
    // boundaries. Regex-based key/quote normalization runs first, THEN
    // the state-aware escape-strip and missing-brace insertion.

    // 3.1: Fix ASYMMETRIC key quotes — model sometimes opens a key with
    //      one quote style and closes with the other: 'title": "Foo" or
    //      "title': "Foo". Rewrite both to "title":.
    s = s.replaceAllMapped(
      RegExp(r'''(['"])([a-zA-Z_][a-zA-Z0-9_]*)['"]\s*:'''),
      (m) => '"${m[2]}":',
    );

    // 3.2: Convert Python-style single-quoted strings to JSON double-quoted.
    //      After this every string is `"..."`, so the state machines
    //      below can track string vs non-string correctly.
    s = _convertSingleQuotedStrings(s);

    // 3.3: Strip stray `\"`, `\n`, `\t`, `\r`, etc. OUTSIDE of strings —
    //      these are invalid JSON syntax. We've seen the model write
    //      `"summary": "x",\n "next":` where `,\n ` is meant as a line
    //      break but is actually a literal backslash + 'n'.
    s = _stripStrayEscapesOutsideStrings(s);

    // 3.4: Insert missing `{` between sibling objects inside arrays. The
    //      model sometimes writes `},\n "title": ...` instead of
    //      `},\n { "title": ...`, dropping the opening brace of every
    //      lesson after the first.
    s = _insertMissingObjectBracesInArrays(s);

    // 4. Inner-quote normalizer — replaces unescaped `"` inside string
    //    values with `'` so they don't confuse the parser.
    s = _normalizeInnerQuotes(s);

    // 4.5: Neutralize invalid escape sequences INSIDE strings. The Gemma
    //      model occasionally emits things like `"answer": "Foo \X bar"`
    //      where `\X` isn't a recognized JSON escape — that fails parsing
    //      with "Unrecognized string escape". Replace each invalid `\X`
    //      with `\\X` so the backslash becomes a properly escaped literal.
    s = _neutralizeInvalidInStringEscapes(s);

    // 5. Strip newlines inside `"key": "value"` strings.
    s = s.replaceAllMapped(
        RegExp(r'":\s*"([^"]*)"', dotAll: true),
        (m) =>
            '": "${m[1]!.replaceAll('\n', ' ').replaceAll('\r', '')}"');

    // 6. Quote bareword array items — including the "dropped opening
    //    quote" case where the model wrote `[36:11809...tasks?", "next"]`
    //    instead of `["36:11809...tasks?", "next"]`.
    s = _quoteUnquotedArrayItems(s);

    // 7. Cheap structural fixes (trailing commas, unquoted keys).
    s = s.replaceAll(RegExp(r',\s*\}'), '}');
    s = s.replaceAll(RegExp(r',\s*\]'), ']');
    s = s.replaceAllMapped(
        RegExp(r'([{,]\s*)([a-zA-Z0-9_]+)\s*:'), (m) => '${m[1]}"${m[2]}":');

    // 8. Force closure for truncated output — track open `{`/`[` and close
    //    them in reverse order. Also close a dangling string.
    final stack = <String>[];
    bool inQuote = false;
    for (int i = 0; i < s.length; i++) {
      if (s[i] == '"' && (i == 0 || s[i - 1] != '\\')) inQuote = !inQuote;
      if (!inQuote) {
        if (s[i] == '{') stack.add('}');
        if (s[i] == '[') stack.add(']');
        if (s[i] == '}' || s[i] == ']') {
          if (stack.isNotEmpty && stack.last == s[i]) stack.removeLast();
        }
      }
    }
    if (inQuote) s += '"';
    while (stack.isNotEmpty) {
      s += stack.removeLast();
    }

    return JsonUtils.cleanJson(s);
  }

  bool _isJsonWhitespace(int code) =>
      code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

  /// Given a `jsonDecode` error message (which typically contains "at line
  /// N, character M"), returns ~6 lines of context around the offending
  /// region. Falls back to the first 400 chars if we can't parse the
  /// location.
  String _extractParseErrorSnippet(String json, String errorMessage) {
    final m = RegExp(r'line (\d+),\s*character (\d+)').firstMatch(errorMessage);
    final lines = json.split('\n');
    if (m == null) {
      final preview =
          json.length > 400 ? '${json.substring(0, 400)}…' : json;
      return preview;
    }
    final line = int.parse(m.group(1)!);
    final col = int.parse(m.group(2)!);
    final start = (line - 3).clamp(1, lines.length);
    final end = (line + 2).clamp(1, lines.length);
    final buf = StringBuffer();
    for (var ln = start; ln <= end; ln++) {
      final text = lines[ln - 1];
      buf.writeln('${ln.toString().padLeft(4)} | $text');
      if (ln == line) {
        final pointer = ' ' * (col + 6) + '^';
        buf.writeln(pointer);
      }
    }
    return buf.toString();
  }

  /// Inside double-quoted strings, replaces any `\X` where X is not a
  /// recognized JSON escape (`"`, `\`, `/`, `b`, `f`, `n`, `r`, `t`, or
  /// `uXXXX`) with `\\X` — i.e. escapes the backslash so the result is
  /// valid JSON that decodes to a literal backslash followed by X. This
  /// fixes "Unrecognized string escape" from `jsonDecode`.
  String _neutralizeInvalidInStringEscapes(String s) {
    final out = StringBuffer();
    bool inStr = false;
    int i = 0;
    final n = s.length;
    final hexDigit = RegExp(r'^[0-9a-fA-F]{4}$');
    while (i < n) {
      final c = s[i];
      if (inStr) {
        if (c == '\\' && i + 1 < n) {
          final next = s[i + 1];
          if (next == '"' ||
              next == '\\' ||
              next == '/' ||
              next == 'b' ||
              next == 'f' ||
              next == 'n' ||
              next == 'r' ||
              next == 't') {
            out.write(c);
            out.write(next);
            i += 2;
            continue;
          }
          if (next == 'u' && i + 6 <= n && hexDigit.hasMatch(s.substring(i + 2, i + 6))) {
            out.write(s.substring(i, i + 6));
            i += 6;
            continue;
          }
          // Invalid escape — escape the backslash literally so the JSON
          // parser sees `\\X`, which decodes to `\` + X.
          out.write(r'\\');
          out.write(next);
          i += 2;
          continue;
        }
        if (c == '"') inStr = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == '"') inStr = true;
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Strips stray escape sequences that the model emits OUTSIDE of strings.
  /// `\"` becomes `"`, `\n`/`\t`/`\r` become spaces, any other `\X`
  /// becomes `X` (drops the backslash). Inside double-quoted strings these
  /// escapes are valid JSON and are preserved as-is.
  String _stripStrayEscapesOutsideStrings(String s) {
    final out = StringBuffer();
    bool inStr = false;
    bool escape = false;
    int i = 0;
    final n = s.length;
    while (i < n) {
      final c = s[i];
      if (inStr) {
        if (escape) {
          escape = false;
          out.write(c);
          i++;
          continue;
        }
        if (c == '\\') {
          escape = true;
          out.write(c);
          i++;
          continue;
        }
        if (c == '"') inStr = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == '"') {
        inStr = true;
        out.write(c);
        i++;
        continue;
      }
      if (c == '\\' && i + 1 < n) {
        final next = s[i + 1];
        if (next == '"') {
          out.write('"');
        } else if (next == 'n' || next == 't' || next == 'r') {
          out.write(' ');
        } else if (next == '\\') {
          // `\\` outside string — drop both (invalid JSON syntax either way).
          // (We keep zero output; the second `\` would be re-escaped on
          // the next iter as a fresh stray.)
        } else {
          out.write(next);
        }
        i += 2;
        continue;
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Inserts a missing `{` when the model writes a `key: value` pair as a
  /// flat sibling inside an array instead of as a proper object. Common
  /// failure mode: lessons 2+ in a workshop are emitted as
  ///     },\n  "title": "Lesson 2", ...
  /// when the model meant
  ///     },\n  { "title": "Lesson 2", ... }
  /// We track the bracket stack and, after a `}` that's a direct child of
  /// an array, the next non-whitespace `"` (start of a key string) gets a
  /// `{` inserted in front of it.
  String _insertMissingObjectBracesInArrays(String s) {
    final out = StringBuffer();
    bool inStr = false;
    bool escape = false;
    final stack = <String>[]; // '{' or '['
    bool justClosedObjInArray = false;
    int i = 0;
    final n = s.length;
    while (i < n) {
      final c = s[i];
      if (inStr) {
        if (escape) {
          escape = false;
          out.write(c);
          i++;
          continue;
        }
        if (c == '\\') {
          escape = true;
          out.write(c);
          i++;
          continue;
        }
        if (c == '"') inStr = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == '"') {
        if (justClosedObjInArray) {
          out.write('{');
          stack.add('{');
          justClosedObjInArray = false;
        }
        inStr = true;
        out.write(c);
        i++;
        continue;
      }
      if (c == '{') {
        stack.add('{');
        justClosedObjInArray = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == '}') {
        if (stack.isNotEmpty && stack.last == '{') stack.removeLast();
        justClosedObjInArray = stack.isNotEmpty && stack.last == '[';
        out.write(c);
        i++;
        continue;
      }
      if (c == '[') {
        stack.add('[');
        justClosedObjInArray = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == ']') {
        if (stack.isNotEmpty && stack.last == '[') stack.removeLast();
        justClosedObjInArray = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == ',') {
        // Comma after `}` in an array — preserve flag, expect either `{`
        // (correct) or `"key":` (wrong, we'll insert).
        out.write(c);
        i++;
        continue;
      }
      if (_isJsonWhitespace(c.codeUnitAt(0))) {
        out.write(c);
        i++;
        continue;
      }
      // Any other non-whitespace, non-string char resets the flag.
      justClosedObjInArray = false;
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Rewrites Python-style single-quoted strings (`'foo'`) as JSON
  /// double-quoted strings (`"foo"`). Walks the input with a small state
  /// machine so apostrophes INSIDE legitimate double-quoted JSON strings
  /// (e.g. `"It's a test"`) are left alone.
  ///
  /// Handles `\'` as a literal apostrophe inside a single-quoted span, and
  /// escapes any unescaped `"` inside as `\"` in the output.
  String _convertSingleQuotedStrings(String s) {
    final out = StringBuffer();
    bool inDouble = false;
    bool dEscape = false;
    int i = 0;
    final n = s.length;
    while (i < n) {
      final c = s[i];
      if (inDouble) {
        if (dEscape) {
          dEscape = false;
          out.write(c);
          i++;
          continue;
        }
        if (c == '\\') {
          dEscape = true;
          out.write(c);
          i++;
          continue;
        }
        if (c == '"') {
          inDouble = false;
        }
        out.write(c);
        i++;
        continue;
      }
      if (c == '"') {
        inDouble = true;
        out.write(c);
        i++;
        continue;
      }
      if (c == "'") {
        // Scan for matching closing `'`, honoring `\'` escapes.
        int j = i + 1;
        bool localEscape = false;
        while (j < n) {
          final cj = s[j];
          if (localEscape) {
            localEscape = false;
            j++;
            continue;
          }
          if (cj == '\\') {
            localEscape = true;
            j++;
            continue;
          }
          if (cj == "'") break;
          j++;
        }
        if (j >= n) {
          // Unterminated — leave the apostrophe alone, don't corrupt.
          out.write(c);
          i++;
          continue;
        }
        final inner = s.substring(i + 1, j);
        out.write('"');
        bool e2 = false;
        for (int k = 0; k < inner.length; k++) {
          final ck = inner[k];
          if (e2) {
            if (ck == "'") {
              // `\'` → literal apostrophe in the new double-quoted string.
              out.write("'");
            } else {
              out.write('\\');
              out.write(ck);
            }
            e2 = false;
            continue;
          }
          if (ck == '\\') {
            e2 = true;
            continue;
          }
          if (ck == '"') {
            // Inner double-quote must be escaped.
            out.write(r'\"');
            continue;
          }
          out.write(ck);
        }
        if (e2) out.write('\\');
        out.write('"');
        i = j + 1;
        continue;
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// State-machine inner-quote normalizer. Treats a `"` as a closing quote
  /// only if it's followed by a JSON structural separator (`:`, `]`, `}`,
  /// or `,` then another value start). Every other in-string `"` becomes
  /// `'` so the parser doesn't see a phantom break.
  String _normalizeInnerQuotes(String s) {
    final out = StringBuffer();
    bool inStr = false;
    bool seenInner = false;
    int i = 0;
    final n = s.length;
    while (i < n) {
      final c = s[i];
      if (inStr && c == '\\' && i + 1 < n) {
        out.write(c);
        out.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == '"') {
        if (!inStr) {
          inStr = true;
          seenInner = false;
          out.write(c);
          i++;
          continue;
        }
        int j = i + 1;
        while (j < n && _isJsonWhitespace(s.codeUnitAt(j))) {
          j++;
        }
        bool closing;
        if (j >= n) {
          closing = true;
        } else {
          final next = s[j];
          if (next == ':' || next == ']' || next == '}') {
            closing = true;
          } else if (next == ',') {
            int k = j + 1;
            while (k < n && _isJsonWhitespace(s.codeUnitAt(k))) {
              k++;
            }
            if (k >= n) {
              closing = true;
            } else {
              final after = s[k];
              final code = after.codeUnitAt(0);
              final isDigit = code >= 0x30 && code <= 0x39;
              final structural = after == '"' ||
                  after == '{' ||
                  after == '[' ||
                  after == ']' ||
                  after == '}' ||
                  after == '-' ||
                  after == 't' ||
                  after == 'f' ||
                  after == 'n' ||
                  isDigit;
              closing = structural ? true : !seenInner;
            }
          } else {
            closing = false;
          }
        }
        if (closing) {
          out.write(c);
          inStr = false;
          seenInner = false;
        } else {
          out.write("'");
          seenInner = true;
        }
        i++;
        continue;
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Detects "dropped opening quote" — model wrote `[bareword text", "next"]`
  /// instead of `["bareword text", "next"]`. Returns the position of the
  /// closing `"` if the pattern is present, else null. Distinguishes from
  /// true unquoted barewords via prose markers (` `, `:`, `?`, `!` etc.).
  int? _findDroppedOpeningClose(String s, int start) {
    final n = s.length;
    int j = start;
    int localDepth = 0;
    bool sawProseMarker = false;
    while (j < n) {
      final c = s[j];
      if (c == '\\' && j + 1 < n) {
        j += 2;
        continue;
      }
      if (c == '"') {
        if (localDepth == 0) {
          int k = j + 1;
          while (k < n && _isJsonWhitespace(s.codeUnitAt(k))) {
            k++;
          }
          final atStructural =
              k >= n || s[k] == ',' || s[k] == ']' || s[k] == '}';
          if (atStructural && sawProseMarker) return j;
          if (atStructural && !sawProseMarker) return null;
        }
        j++;
        continue;
      }
      if (c == '[' || c == '{') {
        localDepth++;
        j++;
        continue;
      }
      if (c == ']' || c == '}') {
        if (localDepth == 0) return null;
        localDepth--;
        j++;
        continue;
      }
      if (c == ',' && localDepth == 0 && !sawProseMarker) {
        return null;
      }
      if (c == ' ' ||
          c == ':' ||
          c == '?' ||
          c == '!' ||
          c == '(' ||
          c == ')' ||
          c == ';') {
        sawProseMarker = true;
      }
      j++;
    }
    return null;
  }

  /// String-aware walker that wraps unquoted array items, including the
  /// dropped-opening-quote case. Only touches barewords at actual array
  /// depth (outside any string).
  String _quoteUnquotedArrayItems(String s) {
    final out = StringBuffer();
    bool inStr = false;
    int arrayDepth = 0;
    bool expectingValue = false;
    int i = 0;
    final n = s.length;
    while (i < n) {
      final c = s[i];
      if (inStr) {
        if (c == '\\' && i + 1 < n) {
          out.write(c);
          out.write(s[i + 1]);
          i += 2;
          continue;
        }
        if (c == '"') {
          inStr = false;
          out.write(c);
          i++;
          continue;
        }
        out.write(c);
        i++;
        continue;
      }
      if (c == '"') {
        inStr = true;
        expectingValue = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == '[') {
        arrayDepth++;
        expectingValue = true;
        out.write(c);
        i++;
        continue;
      }
      if (c == ']') {
        if (arrayDepth > 0) arrayDepth--;
        expectingValue = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == '{' || c == '}') {
        expectingValue = false;
        out.write(c);
        i++;
        continue;
      }
      if (c == ',' || c == ':') {
        expectingValue = true;
        out.write(c);
        i++;
        continue;
      }
      if (_isJsonWhitespace(c.codeUnitAt(0))) {
        out.write(c);
        i++;
        continue;
      }
      if (expectingValue && arrayDepth > 0) {
        // Check dropped-opening BEFORE the number/literal short-circuit —
        // pasted citations often start with digits (e.g. `[36:11809-...`).
        final dropClose = _findDroppedOpeningClose(s, i);
        if (dropClose != null) {
          final inner = s.substring(i, dropClose);
          out.write('"');
          out.write(inner
              .replaceAll('\\', r'\\')
              .replaceAll('"', "'")
              .replaceAll('\n', ' ')
              .replaceAll('\r', ' '));
          out.write('"');
          i = dropClose + 1;
          expectingValue = false;
          continue;
        }
        final code = c.codeUnitAt(0);
        final isDigit = code >= 0x30 && code <= 0x39;
        if (c == '-' || c == 't' || c == 'f' || c == 'n' || isDigit) {
          expectingValue = false;
          out.write(c);
          i++;
          continue;
        }
        // True bareword (no prose markers). Wrap as a string.
        int j = i;
        bool localInStr = false;
        while (j < n) {
          final cj = s[j];
          if (localInStr) {
            if (cj == '\\' && j + 1 < n) {
              j += 2;
              continue;
            }
            if (cj == '"') localInStr = false;
            j++;
            continue;
          }
          if (cj == '"') {
            localInStr = true;
            j++;
            continue;
          }
          if (cj == ',' || cj == ']') break;
          j++;
        }
        final span = s.substring(i, j);
        int trimEnd = span.length;
        while (trimEnd > 0 &&
            _isJsonWhitespace(span.codeUnitAt(trimEnd - 1))) {
          trimEnd--;
        }
        final rawVal = span.substring(0, trimEnd);
        final trailing = span.substring(trimEnd);
        final isNumeric = RegExp(r'^-?\d+(\.\d+)?$').hasMatch(rawVal);
        if (isNumeric ||
            rawVal == 'true' ||
            rawVal == 'false' ||
            rawVal == 'null') {
          out.write(rawVal);
        } else {
          out.write('"');
          out.write(rawVal.replaceAll('"', "'"));
          out.write('"');
        }
        out.write(trailing);
        i = j;
        expectingValue = false;
        continue;
      }
      expectingValue = false;
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Conservative citation detector. Only flags VERY clear copy-paste of
  /// bibliography/reference text — never legitimate technical answers.
  /// We've over-rejected before (legitimate Bayesian-stats answers with
  /// math notation looked citation-shaped), so the thresholds are loose.
  bool _looksLikeCitation(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    // Length cap — generous so verbose technical answers survive.
    if (t.length > 500) return true;
    // Page-range patterns specifically (e.g. "12:345-678" or "12:11809-11822").
    if (RegExp(r'\d+:\d+\d{2,}[-–]\d+').hasMatch(t)) return true;
    // Long author chains: 4+ consecutive "X.," initials.
    if (RegExp(r'(?:[A-Z]\.[A-Z]?\.?,\s*){4,}').hasMatch(t)) return true;
    // DOI / arxiv / isbn explicit prefix.
    if (RegExp(r'\b(?:doi:|arxiv:|isbn:)', caseSensitive: false).hasMatch(t)) {
      return true;
    }
    // Run-together prose with no spaces at all — rare in real answers.
    if (t.length > 120 && !t.contains(' ')) return true;
    return false;
  }

  /// Accepts the several correct-answer field naming conventions the model
  /// swings between: `correct_answer`, `answer` (string match), `answerIndex`
  /// / `correct_index` / `correctIndex` (int into options), and single-letter
  /// "A"/"B"/"C"/"D". Returns the matching option string, or null.
  String? _resolveCorrectAnswer(Map q, List<String> options) {
    final ca = q['correct_answer'];
    if (ca is String && ca.trim().isNotEmpty) {
      final t = ca.trim();
      for (final o in options) {
        if (o == t) return o;
      }
      if (t.length == 1) {
        final idx = t.toUpperCase().codeUnitAt(0) - 0x41;
        if (idx >= 0 && idx < options.length) return options[idx];
      }
    }
    final ans = q['answer'];
    if (ans is String && ans.trim().isNotEmpty) {
      final t = ans.trim();
      for (final o in options) {
        if (o == t) return o;
      }
    }
    final idxField =
        q['answerIndex'] ?? q['correct_index'] ?? q['correctIndex'];
    // Accept any numeric type (Gemma's tool calling sometimes emits 0.0
    // even when the schema declares integer) and clamp to a valid index.
    if (idxField is num) {
      final idx = idxField.toInt();
      if (idx >= 0 && idx < options.length) return options[idx];
    }
    if (idxField is String) {
      final parsed = int.tryParse(idxField.trim()) ??
          double.tryParse(idxField.trim())?.toInt();
      if (parsed != null && parsed >= 0 && parsed < options.length) {
        return options[parsed];
      }
    }
    return null;
  }

  /// Decodes repaired quiz JSON, drops malformed/citation-laden questions,
  /// preserves `answerIndex` for the UI (which expects it), and re-encodes.
  /// THROWS instead of returning broken JSON — we never store a corpse.
  String _validateAndCleanQuiz(String repaired) {
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(repaired) as Map<String, dynamic>;
    } catch (e) {
      final snippet = _extractParseErrorSnippet(repaired, e.toString());
      debugPrint('██████████ JSON REPAIR FAILED ██████████');
      debugPrint('After repair:\n$repaired');
      debugPrint('Parser: $e');
      throw 'The model produced malformed JSON we could not repair. '
          'Please try again.\n\nParser: $e\n\nOffending region:\n$snippet';
    }
    final raw = (decoded['questions'] as List? ?? []);
    final good = <Map<String, dynamic>>[];
    // Track WHY each question got dropped so the error / logs are useful.
    final rejectionCounts = <String, int>{};
    final rejectionSamples = <String, String>{};
    void reject(String reason, Object? sample) {
      rejectionCounts[reason] = (rejectionCounts[reason] ?? 0) + 1;
      rejectionSamples[reason] ??=
          sample?.toString().substring(0, sample.toString().length.clamp(0, 200)) ?? '';
    }

    for (final q in raw) {
      if (q is! Map) {
        reject('not-a-map', q);
        continue;
      }
      final question = q['question'];
      final options = q['options'];
      if (question is! String || question.trim().isEmpty) {
        reject('empty-question', q);
        continue;
      }
      if (options is! List || options.length < 2) {
        reject('options-not-list-or-too-few', options);
        continue;
      }
      final stringOpts =
          options.map((e) => e?.toString() ?? '').toList(growable: false);
      if (stringOpts.any((o) => o.trim().isEmpty)) {
        reject('empty-option', stringOpts);
        continue;
      }
      final citationIdx = stringOpts.indexWhere(_looksLikeCitation);
      if (citationIdx >= 0) {
        reject('citation-shaped-option', stringOpts[citationIdx]);
        continue;
      }
      final correct = _resolveCorrectAnswer(q, stringOpts);
      if (correct == null) {
        reject('no-resolvable-correct-answer', q);
        continue;
      }
      final answerIndex = stringOpts.indexOf(correct);
      good.add({
        'question': question.trim(),
        'options': stringOpts,
        'answerIndex': answerIndex,
        'correct_answer': correct,
        if (q['explanation'] is String) 'explanation': q['explanation'],
      });
    }

    if (good.isEmpty) {
      // Dump diagnostic info to the console for the developer, AND build a
      // user-facing breakdown so the snackbar Details dialog explains what
      // happened instead of giving a vague "no usable questions" string.
      debugPrint('██████████ QUIZ VALIDATION DROPPED ALL ${raw.length} QUESTIONS ██████████');
      rejectionCounts.forEach((reason, count) {
        debugPrint('  $count × $reason  e.g. "${rejectionSamples[reason]}"');
      });
      final breakdown = rejectionCounts.entries
          .map((e) =>
              '  • ${e.value} × ${e.key}\n    e.g. "${rejectionSamples[e.key]}"')
          .join('\n');
      throw 'All ${raw.length} questions from the model were rejected by '
          'validation. Please try again — lowering the question count or '
          'difficulty often helps.\n\nBreakdown:\n$breakdown';
    }
    return jsonEncode({'questions': good});
  }

  String _validateAndCleanFlashcards(String repaired) {
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(repaired) as Map<String, dynamic>;
    } catch (e) {
      final snippet = _extractParseErrorSnippet(repaired, e.toString());
      debugPrint('██████████ JSON REPAIR FAILED ██████████');
      debugPrint('After repair:\n$repaired');
      debugPrint('Parser: $e');
      throw 'The model produced malformed JSON we could not repair. '
          'Please try again.\n\nParser: $e\n\nOffending region:\n$snippet';
    }
    final raw = (decoded['cards'] as List? ?? []);
    final good = <Map<String, dynamic>>[];
    for (final c in raw) {
      if (c is! Map) continue;
      final q = c['question'];
      final a = c['answer'];
      if (q is! String || q.trim().isEmpty) continue;
      if (a is! String || a.trim().isEmpty) continue;
      if (_looksLikeCitation(q) || _looksLikeCitation(a)) continue;
      good.add({'question': q.trim(), 'answer': a.trim()});
    }
    if (good.isEmpty) {
      throw 'The model produced no usable flashcards. Please try again.';
    }
    return jsonEncode({'cards': good});
  }

  List<GeneratedStudyMaterial> getMaterialsForCategory(int categoryId) {
    return _materialBox.query(GeneratedStudyMaterial_.category.equals(categoryId)).build().find();
  }

  /// Calculates the progress percentage (0..1) for a workshop material.
  double workshopProgress(GeneratedStudyMaterial material) {
    if (material.type != 'workshop') return 0.0;
    try {
      final data = jsonDecode(JsonUtils.extractAndCleanJson(material.contentJson)) as Map<String, dynamic>;
      final lessons = (data['lessons'] as List? ?? []);
      if (lessons.isEmpty) return 0.0;

      final completedCount = lessons.where((l) => (l as Map)['completed'] == true).length;
      return completedCount / lessons.length;
    } catch (e) {
      return 0.0;
    }
  }

  Future<GeneratedStudyMaterial> generateWorkshopMaterial({
    required SubjectCategory category,
    int lessonCount = 6,
    WorkshopDepth depth = WorkshopDepth.intermediate,
    void Function(String stage, double progress)? onProgress,
  }) async {
    onProgress?.call('Drafting workshop outline...', 0.0);
    await _ensureModelActive();

    final chunks = await _ragService.searchByCategory(
      'Comprehensive overview of ${category.name} for a structured course',
      category.id,
      maxResults: MemoryGuard.instance.ragChunksForLookup,
    );
    final context = MemoryGuard.instance
        .capContext(chunks.map((c) => c.text).join('\n\n'));

    // Plain English instruction. The schema is enforced by the
    // create_workshop_outline TOOL — the model literally cannot emit
    // invalid structure because the runtime constrains generation at the
    // token level. No JSON repair pipeline, no FormatException.
    final prompt = '''You are designing a structured workshop for a student studying "${category.name}".
Difficulty: ${depth.label}.
${depth.promptGuidance}

Build a course outline of EXACTLY $lessonCount lessons that progresses logically from foundations to advanced. Use the supplied context as the source of truth — do not invent topics that aren't supported by the context.

Call the create_workshop_outline tool with the outline. Every lesson needs a title, a short summary, 2-4 keyPoints, and an estimatedMinutes integer.

Context:
$context''';

    final model =
        await FlutterGemma.getActiveModel(maxTokens: MemoryGuard.instance.maxTokens);
    final chat = await model.createChat(
      temperature: 0.1,
      supportsFunctionCalls: true,
      tools: const [EducationalToolService.workshopOutlineTool],
      toolChoice: ToolChoice.required,
    );
    Map<String, dynamic>? outline;
    try {
      await chat.addQuery(Message.text(text: prompt));
      final response = await chat.generateChatResponse();
      if (response is FunctionCallResponse &&
          response.name == 'create_workshop_outline') {
        outline = Map<String, dynamic>.from(response.args);
      } else if (response is ParallelFunctionCallResponse) {
        for (final call in response.calls) {
          if (call.name == 'create_workshop_outline') {
            outline = Map<String, dynamic>.from(call.args);
            break;
          }
        }
      }
    } finally {
      await chat.close();
    }

    if (outline == null) {
      throw 'The model did not produce a workshop outline. Please try again.';
    }

    final rawLessons = (outline['lessons'] as List? ?? []);
    final lessons = <Map<String, dynamic>>[];
    for (var i = 0; i < rawLessons.length; i++) {
      final l = Map<String, dynamic>.from(rawLessons[i] as Map);
      l['index'] = i;
      l['body'] ??= '';
      l['completed'] ??= false;
      l['completedAt'] ??= null;
      lessons.add(l);
    }

    final workshopJson = {
      'title': outline['title'] ?? '${category.name} Workshop',
      'description': outline['description'] ?? 'A structured course.',
      'depth': depth.label,
      'lessonCount': lessons.length,
      'lessons': lessons,
      'awardedBadges': <String>[],
    };

    return saveMaterial(
      category: category,
      type: 'workshop',
      content: jsonEncode(workshopJson),
      title: '${category.name} · ${depth.label} workshop',
    );
  }

  Stream<Map<String, dynamic>> generateLessonBodyStream({
    required GeneratedStudyMaterial workshop,
    required int lessonIndex,
  }) async* {
    final data = jsonDecode(JsonUtils.extractAndCleanJson(workshop.contentJson)) as Map<String, dynamic>;
    final lessons = (data['lessons'] as List).cast<Map<String, dynamic>>();
    if (lessonIndex < 0 || lessonIndex >= lessons.length) {
      throw RangeError.value(lessonIndex);
    }
    final lesson = lessons[lessonIndex];

    await _ensureModelActive();

    // Build a COMPACT outline (titles only) instead of dumping the entire
    // workshop JSON — that easily blows past the 2048-token input budget
    // for any workshop with more than a few lessons / non-empty bodies.
    final categoryName = workshop.category.target?.name ?? 'the topic';
    final depthLabel = data['depth'] as String? ?? 'Intermediate';
    final outlineSummary = lessons.asMap().entries.map((e) {
      final title = e.value['title'] ?? 'Lesson ${e.key + 1}';
      return '${e.key + 1}. $title';
    }).join('\n');

    // Pull RAG chunks targeted at THIS lesson — much more useful than
    // re-using the whole workshop blob.
    final keyPoints =
        (lesson['keyPoints'] as List? ?? const []).join(' ');
    final query =
        '${lesson['title']} ${lesson['summary'] ?? ''} $keyPoints'.trim();
    final chunks = await _ragService.searchByCategory(
      query,
      workshop.category.target?.id ?? 0,
      maxResults: MemoryGuard.instance.ragChunksForLookup,
    );
    final context = MemoryGuard.instance
        .capContext(chunks.map((c) => c.text).join('\n\n'));

    final prompt = '''You are writing one lesson in a structured workshop on "$categoryName" (overall difficulty: $depthLabel).

Course outline:
$outlineSummary

Now write the BODY for this specific lesson.
Title: ${lesson['title']}
Summary: ${lesson['summary'] ?? ''}
Key points the lesson must cover:
${(lesson['keyPoints'] as List? ?? const []).map((kp) => '- $kp').join('\n')}

Write a clear, ${depthLabel.toLowerCase()}-level lesson in Markdown. Use:
- A short opening paragraph that motivates the topic.
- Section headings (## Subtopic) where useful.
- Bullet lists for enumerations.
- Code blocks (```) for any code snippets.
- A short "Recap" section at the end with 2-3 takeaways.

DO NOT repeat the lesson title at the top — start straight into the content. Stay grounded in the supplied context.

Context:
$context''';

    // 4096 tokens of headroom — prompt is now small, response can be long.
    final model =
        await FlutterGemma.getActiveModel(maxTokens: MemoryGuard.instance.maxTokens);
    final chat = await model.createChat(temperature: 0.1);
    String fullBody = '';
    try {
      await chat.addQuery(Message.text(text: prompt));
      await for (final resp in chat.generateChatResponseAsync()) {
        if (resp is TextResponse) {
          fullBody += resp.token;
          lesson['body'] = fullBody.replaceAll('```markdown', '```').trim();
          yield lesson;
        }
      }
    } finally {
      await chat.close();
    }
    data['lessons'] = lessons;
    workshop.contentJson = jsonEncode(data);
    _materialBox.put(workshop);
  }

  Future<GeneratedStudyMaterial> generateLessonQuiz({
    required SubjectCategory category,
    required String lessonTitle,
    required String lessonBody,
  }) async {
    await _ensureModelActive();
    // Plain-English prompt — structure is enforced by the create_quiz
    // TOOL, not by prompt wording. The runtime constrains generation at
    // the token level so the model cannot emit broken JSON.
    final prompt = '''Create a 5-question multiple-choice quiz based ONLY on this lesson content.

Every question needs exactly 4 short, plain-text options and a correct answerIndex (0..3). Never include citations, bibliography entries, or raw quotes as options.

Call the create_quiz tool with the questions.

Lesson Title: $lessonTitle
Content:
$lessonBody''';

    final model =
        await FlutterGemma.getActiveModel(maxTokens: MemoryGuard.instance.maxTokens);
    final chat = await model.createChat(
      temperature: 0.1,
      supportsFunctionCalls: true,
      tools: const [EducationalToolService.quizTool],
      toolChoice: ToolChoice.required,
    );

    String content = '';
    try {
      await chat.addQuery(Message.text(text: prompt));
      final response = await chat.generateChatResponse();
      Map<String, dynamic>? args;
      if (response is FunctionCallResponse &&
          response.name == EducationalToolService.quizTool.name) {
        args = Map<String, dynamic>.from(response.args);
      } else if (response is ParallelFunctionCallResponse) {
        for (final call in response.calls) {
          if (call.name == EducationalToolService.quizTool.name) {
            args = Map<String, dynamic>.from(call.args);
            break;
          }
        }
      }
      if (args != null) {
        content = jsonEncode(args);
      } else if (response is TextResponse && response.token.isNotEmpty) {
        // Fallback for model variants that ignore ToolChoice.required —
        // saveMaterial's repair pipeline will sort out the JSON.
        content = response.token;
      }
    } finally {
      await chat.close();
    }

    if (content.isEmpty) {
      throw 'The model did not produce a quiz for "$lessonTitle". Please try again.';
    }
    return saveMaterial(
        category: category, type: 'quiz', content: content, title: 'Quiz: $lessonTitle');
  }

  List<Badge> noteLessonOpened({required GeneratedStudyMaterial workshop, required int lessonIndex}) {
    final data = jsonDecode(JsonUtils.extractAndCleanJson(workshop.contentJson)) as Map<String, dynamic>;
    data['lastAccessedAt'] = DateTime.now().toIso8601String();
    data['lastLessonIndex'] = lessonIndex;
    final newBadges = _maybeAwardMilestoneBadges(workshop, data);
    workshop.contentJson = jsonEncode(data);
    _materialBox.put(workshop);
    return newBadges;
  }

  List<Badge> markLessonComplete({required GeneratedStudyMaterial workshop, required int lessonIndex}) {
    final data = jsonDecode(JsonUtils.extractAndCleanJson(workshop.contentJson)) as Map<String, dynamic>;
    final lessons = (data['lessons'] as List);
    lessons[lessonIndex]['completed'] = true;
    lessons[lessonIndex]['completedAt'] = DateTime.now().toIso8601String();
    final newBadges = _maybeAwardMilestoneBadges(workshop, data);
    workshop.contentJson = jsonEncode(data);
    _materialBox.put(workshop);
    return newBadges;
  }

  List<Badge> _maybeAwardMilestoneBadges(GeneratedStudyMaterial workshop, Map<String, dynamic> data) {
    final awarded = (data['awardedBadges'] as List? ?? []).cast<String>();
    final newBadges = <Badge>[];
    
    void addBadge(String name, String desc) {
      if (!awarded.contains(name)) {
        final b = Badge(name: name, description: desc, dateEarned: DateTime.now());
        b.category.target = workshop.category.target;
        objectBox.store.box<Badge>().put(b);
        newBadges.add(b);
        awarded.add(name);
      }
    }

    if (data['startedAt'] != null) addBadge('Scholar', 'Started your first workshop!');
    final lessons = (data['lessons'] as List);
    final completed = lessons.where((l) => (l as Map)['completed'] == true).length;
    if (completed >= lessons.length) addBadge('Graduate', 'Completed all lessons in this workshop!');

    data['awardedBadges'] = awarded;
    return newBadges;
  }
}
