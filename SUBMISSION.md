*This is a submission for the [Gemma 4 Challenge: Build with Gemma 4](https://dev.to/challenges/google-gemma-2026-05-06)*

## What I Built

**EduCloud** is a fully offline, on-device AI study assistant that turns a learner's own PDFs, textbooks, and lecture screenshots into interactive study materials — multiple-choice quizzes, flashcards, multi-lesson workshops, mind maps, and summaries — without a single byte ever leaving the device.

The problem it solves: today's best AI study tools (NotebookLM, Quizlet AI, Cohere Coral) all require a cloud round-trip. For students in regions with patchy connectivity, students who can't afford recurring AI subscriptions, and students working with sensitive material (medical notes, legal documents, exam prep from licensed textbooks) the cloud is a non-starter. EduCloud delivers the same class of experience — semantic search over a personal library, AI-generated practice material grounded in that library, an interactive tutor — on a phone, with the model running locally and the vector database stored locally.

Concrete capabilities:

- **Local RAG**: PDFs are chunked, embedded via Gecko 512, and indexed in ObjectBox with an HNSW vector index. Searches are millisecond-fast over thousands of chunks.
- **Vision ingestion**: Snap a photo of a textbook page; Gemma 4's vision modality extracts text, and the same RAG pipeline takes it from there.
- **Structured generation via tool calling**: Quizzes, flashcards, and workshop outlines are emitted as constrained function calls so the model literally cannot produce malformed JSON. The runtime rejects invalid tokens at generation time.
- **Streaming Markdown lessons**: Workshop lessons are written incrementally so the user sees the body materialize sentence-by-sentence.
- **Interactive GenUI tutor**: A chat companion that can call action tools mid-conversation — award a badge, start a Pomodoro timer, narrate an explanation, launch a subject-specific mini-game.
- **Background task system**: Generation and ingestion run on non-blocking queues with 6-minute timeouts, per-chunk progress counters, and a Details dialog that surfaces the exact reason on failure.
- **Defense-in-depth JSON repair**: A 9-pass state-aware repair pipeline still runs as a fallback for the rare cases when tool calling isn't honored — so the app degrades gracefully instead of crashing.

Everything is built in Flutter + Dart, with native Gemma 4 inference via the `flutter_gemma` plugin (LiteRT-LM under the hood), and persistence via ObjectBox. iOS, Android, macOS, Linux, and Windows are all supported.

## Demo

Watch the walkthrough on YouTube: **https://youtu.be/dVYz8xq2L_8**

{% embed https://youtu.be/dVYz8xq2L_8 %}

## Code

Full source: **https://github.com/trey-rosius/Local-Educational-App**

Key directories to explore:

- [`lib/services/educational_tool_service.dart`](https://github.com/trey-rosius/Local-Educational-App/blob/master/lib/services/educational_tool_service.dart) — all 8 function-call schemas (quiz, flashcards, workshop, plus 5 interactive tutor tools).
- [`lib/services/study_material_service.dart`](https://github.com/trey-rosius/Local-Educational-App/blob/master/lib/services/study_material_service.dart) — generation entry points + the JSON repair pipeline + semantic validators.
- [`lib/services/rag_service.dart`](https://github.com/trey-rosius/Local-Educational-App/blob/master/lib/services/rag_service.dart) — PDF/image ingestion, batched embedding, HNSW search.
- [`lib/services/background_generation_service.dart`](https://github.com/trey-rosius/Local-Educational-App/blob/master/lib/services/background_generation_service.dart) — the non-blocking task queue that branches between tool-call and text-mode paths.
- [`architecture.excalidraw`](https://github.com/trey-rosius/Local-Educational-App/blob/master/architecture.excalidraw) — full visual architecture diagram (open at https://excalidraw.com).
- [`README.md`](https://github.com/trey-rosius/Local-Educational-App/blob/master/README.md) — complete feature + architecture + failure-mode documentation.

## How I Used Gemma 4

**Model chosen: Gemma 4 E2B (`.task`).**

E2B was the only viable choice for a *truly* on-device application of this scope:

| Variant | Size | Fits on phone? | Why I didn't pick it |
|---|---|---|---|
| **Gemma 4 E2B** | ~4 GB quantized | ✅ | Chosen — see below |
| Gemma 4 E4B | ~8 GB | Borderline | Too large for mid-range Android devices; iOS memory pressure during inference |
| Gemma 4 31B Dense | ~62 GB | ❌ | Cloud-scale only |

E2B hits the sweet spot for what EduCloud needs:

- **Fits in mobile RAM and storage**: ~4 GB on disk, comfortable inference on a 6-8 GB device. Development and live testing was done on an **iPhone 13 Pro Max** (6 GB RAM, A15 Bionic, 2021 hardware) — generation, vision OCR, and HNSW vector search all run smoothly there, which means the app targets phones that have been on the market for several years rather than only the latest flagship.
- **Vision modality**: ingest pages from photos via `Message.withImage(...)` — critical for the "snap a textbook page" feature.
- **Function calling**: this is the linchpin of the architecture. With `ToolChoice.required` + a `Tool` schema, structured generation is *guaranteed valid* — no JSON parsing failures possible. Before migrating to tool calling I had to maintain a ~700-line state-aware JSON repair pipeline to handle every quirk the model produced (asymmetric quotes, missing braces, Python-style single quotes, `\X` escapes outside strings, `0.0` as `answerIndex` instead of `0`, citation paste-throughs…). After the tool-calling migration, that pipeline is now a fallback that almost never fires.
- **4096-token context**: large enough to inject 4-6 RAG chunks plus the tool schema plus a 10-question quiz response — but small enough to keep latency reasonable.
- **Multilingual quality**: works well for non-English study material out of the box.

How Gemma 4 is wired into the app, end to end:

1. **Embedding (Gecko 512)**: 512-dim sentence embeddings via `flutter_gemma`'s `Embedder.generateEmbeddings(List<String>)` batch API. Ingestion runs ~10× faster than per-chunk thanks to batching.
2. **RAG retrieval**: HNSW nearest-neighbor search over `Float32List(512)` embeddings in ObjectBox.
3. **Generation with tool calling**: `model.createChat(supportsFunctionCalls: true, tools: [...], toolChoice: ToolChoice.required)` returns a `FunctionCallResponse` with already-parsed `Map<String, dynamic>` args. The runtime constrains generation at the token level.
4. **Streaming text generation**: lesson bodies use `chat.generateChatResponseAsync()` so the user sees Markdown materialize in real time.
5. **Vision OCR**: image ingestion uses `Message.withImage` with the same Gemma 4 model — no separate OCR engine needed.
6. **Resource lifecycle**: `chat.close()` after each generation releases the KV cache; the model is reused as a singleton across tasks (closing it triggers a native double-free at the LiteRT layer).

The most valuable Gemma 4 feature for a project like this was **tool calling**. Pre-Gemma-4 on-device LLMs would emit free-form JSON that I'd have to regex-and-state-machine my way through. With function calling, structured output is *guaranteed* — which is what made the offline study-material generation feel as reliable as a cloud product.

Sampling tuned for this app: `temperature: 0.3, topK: 40, topP: 0.95` for tool calling (Gemma's published guidance for structured outputs — greedy decoding `temp~0, topK=1` is prone to short repetition loops on long structured responses).

---

*Built with Flutter, Dart, `flutter_gemma`, ObjectBox, LiteRT-LM, and a healthy disregard for cloud dependencies.*
