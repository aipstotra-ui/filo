# AI-Engine (built in M3 — 2026-07-18)

The local brain: **Apple's built-in on-device model** (FoundationModels framework, ships with macOS 26 — founder decision 2026-07-17, superseding the MLX+Qwen plan). No download, no third-party AI dependency, no network call at all. Requires Apple Intelligence enabled; when it isn't, the app says so honestly and degrades to name-and-type.

Receives snippets from [[Extraction]]; sends summary + sanitized name + embedding onward (embedding consumed by [[Folder-Index]] in M4).

## How one file flows through

1. `AIEngine` checks model availability and maps every unavailable state to an honest menu line (Apple Intelligence off / device ineligible / model still preparing).
2. `PromptBuilder` fences the snippet between explicit delimiters — instructions first, content last, introduced as *data, not instructions* ([[ai-engineering]]).
3. A **fresh `LanguageModelSession` per generation** asks for structured output (`@Generable`: one-line summary + filename base). Sessions are stateful chat transcripts — reusing one across files would leak one file's content into the next file's prompt, so we never do.
4. Greedy sampling first (same file → same suggestion); a malformed answer gets exactly one retry with default sampling; 60 s timeout, late results dropped.
5. Output enforcement: `FilenameSanitizer` (path separators, control + bidi/invisible Unicode, lookalike separators, extension re-applied in code, 100-char cap) and `SummarySanitizer` (same scalar stripping, one line, 120 chars). No raw model string ever reaches the UI or a filesystem API.
6. `EmbeddingProvider` (built-in NLEmbedding) vectorizes the snippet for M4 folder matching — bounded at 10 s; the suggestion ships without it rather than wait.

The `AIProviding` protocol is the module boundary — it keeps a swap-back path to MLX+Qwen open if suggestion quality disappoints.
