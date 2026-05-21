*This is a submission for the [Gemma 4 Challenge: Build with Gemma 4](https://dev.to/challenges/google-gemma-2026-05-06)*

## What I Built

### Why I built it

I run [**Educloud Academy**](https://educloud.academy), a learning platform focused on cloud and AI skills for African students. Over the last year my team and I have done university outreach across **10 Cameroonian universities** — including my own alma mater, the **University of Buea** — running on-the-ground sessions on how to break into cloud and AI careers.

*Outreach evidence (LinkedIn):*

- [Continuing our university outreach](https://www.linkedin.com/posts/rosius_continuing-our-university-outreach-this-activity-7418985734780473345-gc7r) — University of Buea session
- [EduCloud Academy: outreach announcement](https://www.linkedin.com/posts/educloud-academy_educloudacademy-ugcPost-7345085251271991296-W11K)
- [Student testimonial post](https://www.linkedin.com/posts/kenn-brayan-nya-527846336_ndimoforatehrosius-cabreldomfang-ugcPost-7344652264915046401--ErQ)
- [Earlier outreach activity](https://www.linkedin.com/feed/update/urn:li:activity:7351200292027129856/)

*(Photos from these sessions attached below this post.)*

Two problems kept showing up at every single campus, no matter the topic:

1. **The internet is unreliable.** Students who'd love to use ChatGPT, NotebookLM, Claude, or Cohere Coral simply can't, because their connection drops mid-prompt, the data is expensive, or campus Wi-Fi can't sustain a real session. AI tools that require a cloud round-trip are *unusable* for the majority of the students I've met.
2. **Most of Cameroon is French-speaking.** A huge chunk of every audience I've sat in front of doesn't have English as a first language. But almost every AI study tool ships English-first, with French either missing or relegated to lossy machine translation that strips technical nuance.

**EduCloud (the app)** is my answer to both. It's a fully offline, on-device AI study assistant that turns a learner's own PDFs, textbooks, and lecture screenshots into interactive study materials — multiple-choice quizzes, flashcards, multi-lesson workshops, mind maps, and summaries — **without a single byte ever leaving the device**. Because Gemma 4 is genuinely multilingual, the *same* binary that serves an English-speaking student in Yaoundé serves a French-speaking student in Douala without an extra translation hop.

### What it does

- **Local RAG**: PDFs are chunked, embedded via Gecko 512, and indexed in ObjectBox with an HNSW vector index. Searches are millisecond-fast over thousands of chunks.
- **Vision ingestion**: Snap a photo of a textbook page or whiteboard; Gemma 4's vision modality extracts the text, and the same RAG pipeline takes it from there. (Critical for students working from photocopied notes.)
- **Structured generation via tool calling**: Quizzes, flashcards, and workshop outlines are emitted as constrained function calls so the model literally cannot produce malformed JSON. The runtime rejects invalid tokens at generation time.
- **Streaming Markdown lessons** with visible chain-of-thought: workshop lessons stream sentence-by-sentence, and Gemma 4's reasoning channel renders in a collapsible "thinking" panel so students can *see how the model arrived at an answer*.
- **Interactive GenUI tutor**: a chat companion that can call action tools mid-conversation — award a badge, start a Pomodoro timer, narrate an explanation aloud, launch a subject-specific mini-game.
- **Adaptive memory tiers**: the app detects the device's total RAM at startup (`ultraLean / lean / balanced / full`) and adjusts token budgets, RAG context size, and max question count so it runs cleanly on the iPhone 13 Pro Max I tested on as well as on lower-end mid-range Androids that students actually own.
- **Background task system**: generation and ingestion run on non-blocking queues with hard timeouts, per-chunk progress counters, and a Details dialog that surfaces the exact reason on failure.
- **Defense-in-depth JSON repair**: a 9-pass state-aware repair pipeline still runs as a fallback for the rare cases when tool calling isn't honored — so the app degrades gracefully instead of crashing.

Everything is built in Flutter + Dart, with native Gemma 4 inference via the `flutter_gemma` plugin (LiteRT-LM under the hood), and persistence via ObjectBox. iOS, Android, macOS, Linux, and Windows are all supported from one codebase — important because campus device fleets aren't uniform.

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
- **Multilingual quality out of the box**: this matters more than any feature on this list for my actual user base. Cameroon has 10 French-speaking and 2 English-speaking regions. Gemma 4 handles French content (and reasoning *in* French) at quality that's roughly on par with English — so the same app, with no extra translation layer or per-language fork, serves a francophone student in Yaoundé as well as an anglophone student in Buea. Cloud APIs charge per token; switching languages on-device is free.

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

## What this unlocks for the students I've actually met

The next time I walk onto a Cameroonian campus to talk about cloud and AI careers, I won't have to caveat the AI portion of the talk with "…of course you'll need stable internet and an English-fluent prompt." I can hand a student a Gemma-4-powered app, watch them point it at their own French-language course PDF, and watch them get a quiz in French, generated on-device, with no data plan involved.

That's the bar for AI tools that actually work for the next billion learners — and that's the bar Gemma 4 cleared.

---

*Built with Flutter, Dart, `flutter_gemma`, ObjectBox, LiteRT-LM, and a healthy disregard for cloud dependencies.*

*Follow me on [LinkedIn](https://www.linkedin.com/in/rosius/) or check out [EduCloud Academy](https://educloud.academy) for what comes next.*
