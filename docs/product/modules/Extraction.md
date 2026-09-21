# Extraction (built in M2)

Reads what's inside a new file and turns it into a short text snippet, so the [[AI-Engine]] has something to understand. Receives stable files from [[Watcher]] (via `PipelineModel` in [[Popup-UI]]); snippets stay **in memory only** — never written to disk or logs (see [[decisions]]).

Every file produces a result — there is no silent failure. If the content can't be read, the snippet falls back to filename + type + size + created date, with a typed reason the UI can show.

## The pieces

- `Sources/FileOrganizer/Extraction/ExtractionEngine.swift` — the router. One serial background queue (one file at a time keeps the Mac responsive), picks the right extractor by file type, enforces the snippet budget centrally, and builds the metadata fallback. Completion always lands on the main queue.
- `Sources/FileOrganizer/Extraction/PDFTextExtractor.swift` — digital PDFs: reads the text layer, first 10 pages max. Scanned PDFs (no text layer): renders page 1 and OCRs it. Rejects only *locked* PDFs — `isLocked`, not `isEncrypted` — because owner-password PDFs (bank statements, e-tickets) open and read fine.
- `Sources/FileOrganizer/Extraction/ImageOCRExtractor.swift` — screenshots and images via Apple Vision (`.accurate`, on-device). Decodes through a capped thumbnail so a tiny PNG that would decompress to gigabytes (a "decompression bomb") can't exhaust memory.
- `Sources/FileOrganizer/Extraction/PlainTextExtractor.swift` — txt, md, csv, source code. Reads only the first 64 KB. UTF-16 files (spotted by their byte-order mark) are decoded before the NUL-byte binary gate, because UTF-16 legitimately contains NUL bytes. A printability check rejects binary files wearing a `.txt` name.
- `Sources/FileOrganizer/Extraction/ContentExtracting.swift` — the module-boundary protocol (file event in, snippet out, completion called exactly once).
- `Sources/FileOrganizer/Extraction/ExtractedContent.swift` — the result type, plus the `ExtractionMethod` and `FallbackReason` enums.

## Routing rules (in order)

1. PDF → `PDFTextExtractor` (skipped if over 200 MB)
2. **SVG → `PlainTextExtractor`** — SVG counts as both "image" and "text" to macOS; it's XML, and OCR can't decode it, so the text check must win. Deliberately checked *before* the image rule.
3. Image → `ImageOCRExtractor`
4. Text → `PlainTextExtractor`
5. Anything else (zips, videos, apps…) → metadata fallback

## Caps & limits

| What | Limit | Why |
|---|---|---|
| Snippet | 4000 characters / 500 words, cut on a word boundary | Enough for the AI, bounded memory |
| PDF file size | 200 MB | A malformed giant PDF can hang the parser |
| PDF pages | First 10 (stops earlier once the word budget is met) | First pages carry the identity of a document |
| Scanned PDF | Page 1 only, rendered ≤1600×2000, then OCR | One page is enough to name a scan |
| Image file size | 30 MB | OCR on RAW-photo-sized files is rarely useful |
| Image decode | ≤4000 px thumbnail (`CGImageSourceCreateThumbnailAtIndex`) | Bounds *decoded* memory — file size alone doesn't |
| Plain text read | First 64 KB | A gigabyte log costs the same as a note |
| Per-file time | 60 s (enforced by `PipelineModel` in [[Popup-UI]]) | A hung read must not stick on "Reading…" forever |

## Fallback reasons (`FallbackReason`)

When content can't be read, the result says why — shown in the menu as "*reason* — using name & type":

| Reason | Means |
|---|---|
| `unsupportedType` | No extractor for this kind of file (zip, video…) — the normal case, shown as just "Using name & type" |
| `emptyFile` | File is 0 bytes |
| `fileDisappeared` | Moved/deleted between announce and read |
| `noPermission` | macOS denied the read |
| `unreadableFile` | Couldn't open/decode the file at all |
| `passwordProtected` | PDF is locked (needs a user password) |
| `noReadableText` | Opened fine, but nothing text-like inside |
| `scanFailed` | OCR/render itself failed — *our* failure, not "no text" |
| `tooLarge` | Over the size cap |
| `timedOut` | Took over 60 s |
| `binaryContent` | Claims to be text but the bytes are binary |

## Dev logging

Normal runs log **filename, method, and word count only** — never content — and filenames go through `LogSanitizer` (see [[Watcher]]) because filenames are attacker-controlled too. Setting `FILE_ORGANIZER_DEBUG_SNIPPETS=1` additionally prints a sanitized 200-character snippet preview (founder-approved dev-only privacy exception, 2026-07-17; on the M6 release checklist to remove — see [[milestones]]).

## Talks to

- Consumes stable-file events from [[Watcher]], wired up by `PipelineModel` in [[Popup-UI]].
- Will feed snippets to [[AI-Engine]] from M3; today the result is shown as a status line in the menu.
