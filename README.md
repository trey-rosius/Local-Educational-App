# EduCloud: On-Device AI Study Hub 🚀

EduCloud is a premium, offline-first educational platform that leverages on-device LLMs (Google Gemma 4) to transform local documents into immersive, interactive learning experiences.

Designed for students who need a distraction-free, privacy-preserving environment, EduCloud brings Generative UI (GenUI), Retrieval-Augmented Generation (RAG), **and constrained function-call generation** directly to the edge.

---

## 🌟 Key Features

- **Local Document Ingestion (RAG)**: Turn PDFs, textbooks, and images into a searchable knowledge base. All chunking, vectorization, and retrieval happen on-device using a local Gecko 512 embedder with per-page + per-chunk progress.
- **Structured Workshops**: Auto-generated multi-lesson courses with learning objectives, lazy-loaded lesson bodies (streaming Markdown), and milestone badges.
- **Interactive Quizzes & Flashcards**: AI-generated study materials grounded in your own documents — and guaranteed structurally valid via flutter_gemma's function-calling API.
- **GenUI-Lite Chat**: An interactive tutor that doesn't just talk — it acts. The AI triggers focus timers, awards achievement badges, narrates explanations, and launches subject-specific mini-games.
- **Background Task Queues**: Generation and ingestion run on non-blocking queues with timeouts, retries, and visible per-chunk progress. No more frozen spinners.
- **Premium UX**: A "glassmorphic" design system with smooth animations and a dark-mode-optimized interface for long study sessions.

---

## 🏗️ Technical Architecture

A full visual diagram is at [`architecture.excalidraw`](architecture.excalidraw) — open it on https://excalidraw.com (File → Open). Highlights below.

### 1 · On-Device AI Engine

EduCloud uses the `flutter_gemma` plugin (^0.15.1) to run **Google's Gemma 4 E2B** locally via LiteRT-LM, plus **Gecko 512** for sentence embeddings.

- **Privacy**: No user data, documents, or chat history ever leave the device.
- **Offline Access**: Fully functional with zero connectivity once models are downloaded.
- **Models**: Gemma 4 E2B `.task` (~4 GB, 4096 token context) for generation + vision OCR; Gecko 512 `.tflite` for 512-dim retrieval embeddings.
- **Native runtime**: LiteRT-LM prebuilt dylibs for iOS / macOS / Linux / Windows / Android, fetched once by `hook/build.dart` from a SHA256-pinned GitHub Release.

### 2 · Function-Calling (Constrained Generation)

The biggest reliability upgrade in EduCloud: quiz, flashcards, and workshop outlines are generated via **tool calling with `ToolChoice.required`**. The runtime constrains generation at the token level so the model **literally cannot emit invalid JSON** — there is no parsing step that can fail.

- Each structured content type has a schema defined in `EducationalToolService`.
- `BackgroundGenerationService` branches on type and creates the chat with the matching tool.
- The response comes back as a `FunctionCallResponse` with already-parsed `Map<String, dynamic>` args.
- Falls back gracefully to text-mode + JSON repair if a model variant ignores the constraint, so you always get *some* result.

### 3 · Universal JSON Repair Pipeline (legacy fallback)

Still in place as a defensive backstop for `mind_map` (no schema yet) and as the fallback path when tool calling isn't honored. The `_universalGemmaRepair` pipeline runs a series of state-aware passes:

| Pass | What it fixes |
|---|---|
| Smart-quote normalization | `"` `"` `'` `'` → ASCII quotes |
| Asymmetric key quotes | `'title": "Foo"` → `"title": "Foo"` |
| Single-quote conversion | `{'title': 'Foo'}` → `{"title": "Foo"}` |
| Stray escapes outside strings | `,\n` (literal backslash-n) → `, ` |
| Missing object braces in arrays | `},\n "title": ...` → `},\n {"title": ...}` |
| Inner-quote normalizer | Unescaped `"` inside strings → `'` |
| Invalid in-string escapes | `\X` → `\\X` (fixes "Unrecognized string escape") |
| Dropped opening quote on array item | `[36:11809-...]` → `["36:11809-..."]` |
| Force-closure | Adds missing `}`/`]` to truncated output |

After repair, `_validateAndCleanQuiz` / `_validateAndCleanFlashcards` drop semantically-bad entries (citation-shaped options, empty strings, unresolvable answers) and re-encode. **Invalid JSON is never stored** — saves either succeed with clean content or throw a clean retry message.

### 4 · Retrieval-Augmented Generation (RAG)

- **Vector Database**: ObjectBox with **HNSW** index on `Float32List(512)` embeddings for fast nearest-neighbor search.
- **Chunking**: `RecursiveCharacterTextSplitter` (chunk size 400, overlap 50). Chunks shorter than 20 chars are dropped (titles, page numbers, junk).
- **Batched embedding**: `Embedder.generateEmbeddings(List<String>)` — 32 chunks per native call, ~10× faster than per-chunk.
- **Per-page + per-chunk progress**: `onPageProgress` and `onChunkProgress` callbacks surface live counters like `Page 87 of 205` / `Embedded 287 of 412 chunks`.
- **Contextual injection**: For tool-call types, RAG context is kept small (4-6 chunks) to leave headroom for the response and tool schema.
- **Vision OCR**: Images go through Gemma 4's vision modality (`Message.withImage`) for text extraction before chunking.

### 5 · Background Task System

Two `ChangeNotifier` singletons run non-blocking task queues so the UI never blocks on model inference.

**`BackgroundGenerationService`** (quiz / flashcards / workshop generation)
- FIFO queue with one task in-flight at a time (the model is a singleton).
- 6-minute hard timeout per task — failed timeouts surface as a snackbar with the reason.
- `_toolForType(type)` maps content types to function-call schemas.
- Routes saves through `StudyMaterialService.saveMaterial` so semantic validators always run.
- Sends a notification on success or failure.

**`BackgroundIngestionService`** (PDF + image ingestion)
- FIFO queue, same singleton pattern.
- Phase A (text extraction): yields one frame per page so the UI keeps painting.
- Phase B (embedding): batched 32 chunks per call with a 1-frame yield between batches.
- Falls back to per-chunk embedding if the batch API fails on the active embedder.

### 6 · GenUI-Lite Chat Architecture

For the conversational tutor, `EducationalToolService.educationalTools` defines five **action** tools the model can call during chat. The UI detects `FunctionCallResponse` and renders native Flutter widgets inline (no markdown, no parsing).

---

## 🛠️ Tool Catalog

Eight function-calling tools are defined in [`lib/services/educational_tool_service.dart`](lib/services/educational_tool_service.dart):

### Generation tools (used for structured content)

| Tool | Purpose | Schema (top-level) |
|---|---|---|
| `create_quiz` | Multi-question MCQ quiz | `questions: [{question, options[4], answerIndex, explanation}]` |
| `create_flashcards` | Q&A study cards | `cards: [{question, answer}]` |
| `create_workshop_outline` | Multi-lesson course outline | `{title, description, lessons: [{title, summary, keyPoints[], estimatedMinutes}]}` |

Used by `StudyMaterialService.generateWorkshopMaterial`, `generateLessonQuiz`, and `BackgroundGenerationService._processNextTask`. `ToolChoice.required` forces the model to emit a function call, eliminating JSON parsing as a failure surface.

### Interactive tutor tools (used in chat)

| Tool | Purpose | Schema |
|---|---|---|
| `generate_interactive_quiz` | Inline mini-quiz during a chat | `{subject, questions: [{question, options[], correct_answer, explanation}]}` |
| `award_badge` | Celebrate a learning milestone | `{badge_name, reason, animation_type}` |
| `start_focus_timer` | Pomodoro-style focus session | `{duration_minutes, focus_topic}` |
| `narrate_explanation` | TTS readback | `{text_to_read, voice_style}` |
| `launch_mini_game` | Subject-specific interactive game | `{game_type, difficulty}` |

The chat layer (`createEducationalChat`) loads all five with `supportsFunctionCalls: true` and lets the model decide which (if any) to call based on conversation context.

---

## 🛠️ Tech Stack

- **Framework**: Flutter (Dart)
- **AI Models**: Gemma 4 E2B (text + vision + tool calling), Gecko 512 (embeddings)
- **AI Plugin**: [`flutter_gemma`](https://pub.dev/packages/flutter_gemma) ^0.15.1 (LiteRT-LM under the hood)
- **Database**: [`objectbox`](https://pub.dev/packages/objectbox) — NoSQL with HNSW vector index
- **PDF Parsing**: `syncfusion_flutter_pdf`
- **Text Splitting**: `langchain` (`RecursiveCharacterTextSplitter`)
- **TTS**: `flutter_tts`
- **Confetti / Animations**: `confetti`, custom Glass theme
- **Notifications**: `flutter_local_notifications`

---

## 📁 Project Structure

```
lib/
├── main.dart                          // Entry point + ObjectBox init
├── models/
│   ├── entities.dart                  // ObjectBox entities (5 tables)
│   ├── model.dart                     // Gemma 4 metadata
│   ├── embedding_model.dart           // Gecko 512 metadata
│   └── base_model.dart                // Shared base class
├── services/
│   ├── study_material_service.dart    // Prompts + repair pipeline + validators
│   ├── rag_service.dart               // PDF ingest + chunking + HNSW search
│   ├── educational_tool_service.dart  // All 8 tool schemas
│   ├── background_generation_service.dart  // Generation task queue
│   ├── background_ingestion_service.dart   // Ingestion task queue
│   ├── model_download_service.dart    // Gemma 4 download
│   ├── embedding_download_service.dart     // Gecko 512 download
│   ├── notification_service.dart      // Local push notifications
│   ├── tts_service.dart               // Text-to-speech
│   ├── auth_token_service.dart        // Hugging Face token storage
│   ├── knowledge_share_service.dart   // Peer-to-peer material sharing
│   ├── usage_tracking_service.dart    // Local analytics
│   └── objectbox_manager.dart         // DB lifecycle
├── screens/
│   ├── main_navigation_screen.dart    // Bottom-nav shell
│   ├── study_hub_screen.dart          // Generate quiz/flashcards/workshop
│   ├── ingestion_workflow_screen.dart // PDF/image upload + progress
│   ├── workshop_screen.dart           // Workshop overview
│   ├── lesson_screen.dart             // Individual lesson reader + per-lesson quiz
│   ├── quiz_screen.dart               // Quiz player
│   ├── analytics_screen.dart          // Usage stats
│   └── settings_screen.dart           // Preferences
├── widgets/
│   ├── educational_widgets.dart       // QuizCard, FlashcardCarousel, badges
│   ├── glass_theme.dart               // Glassmorphic color/decoration system
│   └── universal_model_card.dart      // Model download UI
└── utils/
    ├── json_utils.dart                // Minimal JSON cleanup helpers
    ├── audio_converter.dart           // PCM ↔ WAV conversion
    └── platform_io*.dart              // Web/IO conditional imports

architecture.excalidraw                // Full visual architecture diagram
prompts.md                             // Catalog of model prompts
```

---

## 🚀 Getting Started

1. **Clone & install**:
   ```bash
   flutter pub get
   ```
2. **Native dependencies**:
   - iOS: `cd ios && pod install --repo-update`
   - Android: ensure `minSdkVersion` ≥ 21
3. **First launch**:
   - Open the Model Downloads screen → grab Gemma 4 E2B (~4 GB) and Gecko 512 (~80 MB).
   - LiteRT-LM native dylibs are downloaded automatically by `hook/build.dart` during build, SHA256-pinned to a specific GitHub Release.
4. **Add a subject**:
   - In Knowledge Ingestion, type a category name and upload a PDF or image.
   - Wait for "Embedded N of N chunks" to complete.
5. **Generate**:
   - Open the subject's Study Hub → tap Quiz / Cards / Workshop.
   - Generation runs in the background; you'll get a notification on completion (or a snackbar on failure with a Details button).

---

## 🧯 Failure Modes & Recovery

EduCloud is built around the assumption that on-device generation will occasionally fail. Every failure has a clean, visible recovery path:

| Failure | Surface | Recovery |
|---|---|---|
| Generation timeout (6 min) | Snackbar + notification | "Try again — lowering the question count often helps" |
| Tool call ignored by model | Silent fallback to JSON repair | Result still saved; logged in console |
| JSON repair fails | Snackbar with offending region | Tap **Details** for full multi-line error |
| Validator drops all questions | Snackbar with per-rule breakdown | Console shows which rule fired on which option |
| Empty model response | "Model returned empty response" | One-tap retry |
| KV-cache leak | Auto-released via `chat.close()` in `finally` | No action needed |
| Native double-free | Prevented by never calling `model.close()` | Singleton model is reused across tasks |

---

## 📊 Architecture Diagram

Open [`architecture.excalidraw`](architecture.excalidraw) in https://excalidraw.com or the desktop app for the full picture. Seven layers, color-coded flows for generation (blue), ingestion (orange), and RAG search (green).

---

## 📄 Prompts

A complete catalog of system prompts and tool-call instructions used to guide the model is in [`prompts.md`](prompts.md).

---

## 🏆 Competition Merit

EduCloud demonstrates that **sophisticated AI isn't dependent on the cloud**. By combining:

- Local RAG with HNSW vector search,
- Constrained generation via tool calling,
- A defensive JSON repair pipeline,
- Non-blocking background task queues with visible progress,
- Graceful failure surfaces,
- Premium glassmorphic UI/UX,

we've created a study tool that is private, permanent, and performant — setting a new bar for on-device generative applications.
