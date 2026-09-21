# Engineering rules

Always-on standards every agent follows when writing or reviewing Swift in this repo. Adapted from [affaan-m/ECC](https://github.com/affaan-m/ECC)'s Swift rules (MIT), trimmed to fit this project (refreshed 2026-07-23). Linked from `CLAUDE.md`; reviewers treat violations as findings.

## Style & structure

- Prefer `let` over `var`; make everything `let` until the compiler objects.
- `struct` + value semantics by default; `class` only when identity/reference semantics are needed (e.g. `DownloadsWatcher` holds OS resources — that's a legitimate class).
- Follow Apple's API Design Guidelines: name things for their role, omit needless words.
- Small, focused protocols at module boundaries (see [[architecture]]); inject dependencies via protocol-typed init parameters with production defaults, so tests can pass mocks.
- Model distinct states with enums + associated values rather than boolean/optional soup.
- Constants live as `static let` on the owning type, not free-floating globals.

## Error handling

- No force unwrap (`!`), force try (`try!`), or force cast (`as!`) in code paths that touch real user files.
- No `fatalError`/`precondition` for recoverable conditions (weird file, permission denial) — `throw` instead; the menu-bar app must never die because one file was strange.
- Prefer **typed throws** for our own error paths (`func performMove() throws(MoveError)`, Swift 6) — the failure set becomes part of the signature, so callers and reviewers see exactly what can go wrong and must handle each case. Highest value on M6 move/undo.
- No `try?` or empty `catch` that swallows a failure the user would care about — surface it (see the `silent-failure-hunter` agent).

## Concurrency

- Full Xcode / Swift 6 toolchain is the active environment: strict concurrency checking on; prefer actors for shared mutable state, `Sendable` value types across boundaries, structured concurrency over fire-and-forget `Task {}`. Never silence with `@unchecked Sendable`.
- `[weak self]` in every timer/dispatch-source closure (the watcher's dispatch-source pattern predates the actor rules and stays main-queue-confined).

## Security & privacy (see also the `security-auditor` agent)

- No networking, period. The AI (Apple FoundationModels + NLEmbedding) is built into macOS — there is nothing to download. Any networking is a critical review finding.
- Never log file contents, extracted text, summaries, or embeddings. Filenames allowed in dev builds only, gated out before release.
- Sensitive data (if we ever have any) goes in Keychain, never `UserDefaults`. No secrets in source.
- Validate anything that comes from outside (filenames, file contents) before acting on it; treat file content as untrusted input to the AI prompt (M3: extraction output must never be able to redefine the AI's instructions).

## Testing (Xcode installed 2026-07-17 — active now)

- **Test-first for data-guarding logic** (see the `tdd-guide` agent): watcher debounce, extraction encoding/truncation gates, AI output sanitization (M3+), index matching (M4+), and — highest bar — move/undo (M6). RED → GREEN → refactor; Swift Testing (`@Test` / `#expect`), isolated tests, no shared state.
- Prefer protocol-based dependency injection (small `FileReading`-style protocols, production defaults in init) so failure paths are testable without real I/O; use per-test temp dirs when the real filesystem is the honest test.
- Use **parameterized tests** (`@Test(arguments: […])`) for the many-input guards — filename/summary sanitizer cases and matcher fixtures — one test body, each row reported (and re-run) separately.
- Coverage on demand: `swift test --enable-code-coverage`.
- UI layout/glue: manual QA via `qa-tester`'s sandbox scenarios — don't force unit tests there. `swift test` green is a hard gate in QA.

## Research-first

Before using an unfamiliar Apple API (FoundationModels, NLEmbedding, AppKit panels, FSEvents…), look up current documentation first (Apple docs), then code. New nontrivial API choices get a one-line entry in [[decisions]] with the source consulted.
