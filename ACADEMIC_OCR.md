# Vision Notes Academic OCR

The Academic tab converts photographed mathematical notes into editable Markdown and LaTeX source, an offline standalone HTML document, a searchable semantic PDF with heading-based navigation, a source-page facsimile, provider evidence JSON, extracted figures, and an artifact ZIP.

## Local key setup

The repository tracks `VisionNotes/Resources/ProviderKeys.example.plist` with empty values. Copy it to `VisionNotes/Resources/ProviderKeys.plist` and add local `MistralAPIKey` and `SiliconFlowAPIKey` values there. The real file is ignored by Git.

At build time, a script copies the local file into the application bundle as `ProviderKeys.plist`. If the local file is missing, it copies the empty example instead, allowing a clean checkout and CI build to compile without secrets. `ProviderKeys.load()` decodes the resulting bundle resource.

Keys must never be added to Swift source, logs, job manifests, analytics, snapshots, exports, issues, or screenshots. A client application cannot keep a bundled secret from someone who receives the binary. Before distributing the app, use a server-side proxy with authentication, per-user limits, provider-side restrictions, and key rotation.

The ordinary Import tab is separate and continues to use Apple Vision fully on the device.

## Local jobs and privacy

Jobs live under `Application Support/MathNoteJobs/<job-id>/`. Each completed stage is atomically checkpointed. Page-level and request-level caches let Resume reuse completed work instead of knowingly repeating provider requests. A vision batch has a bounded wait; if it pauses or times out, Resume continues from saved stages and retries only unfinished requests.

The initial upload confirmation states that confirmed pages go directly to Mistral for base OCR and SiliconFlow for mathematical vision correction. Provider quotas, retention rules, and privacy terms apply. Nothing else is shared until the user invokes an iOS share/save action.

Delete and Delete All remove local source pages, evidence, edits, and deliverables for the selected jobs.

## Rendering

The semantic PDF is generated on device by a restricted local HTML document in `WKWebView`. Math is converted to MathML without a CDN or remote font/script dependency. Headings are assigned stable anchors so the generated table of contents can jump to sections.

The generated `document.tex` is human-readable, Unicode/CJK-aware XeLaTeX-compatible source. The app does not claim that XeLaTeX produced `document.pdf`; its current semantic PDF renderer is WebKit. The renderer protocol leaves room for a proven App-Store-compatible native TeX engine later.

The standalone HTML embeds figures as data URLs and uses a restrictive Content Security Policy. The facsimile PDF is independently generated from immutable normalized source pages and remains the photographed-layout reference.

## Current limitations

- Handwritten OCR is probabilistic. Review every `[unclear: ...]` marker and compare the semantic result with its source page.
- Perspective correction is conservative to avoid mistaking a drawn rectangle for the paper boundary. VisionKit scans usually provide the strongest page geometry.
- The local MathML converter covers common fractions, scripts, radicals, accents, Greek symbols, operators, and matrix environments. Uncommon LaTeX packages or macros remain in the exported `.tex` source but may display literally in the WebKit PDF.
- Semantic reconstruction preserves meaning and hierarchy; it cannot be pixel-identical to arbitrary handwriting. Use facsimile artifacts when exact visual placement matters.
- Very large PDFs, HTML documents, or ZIP archives are rejected by explicit local limits.
