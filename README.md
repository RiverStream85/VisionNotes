# Vision Notes

Vision Notes is an iOS notebook for scanning, recognizing, searching, and exporting notes. Its ordinary Library/Import workflow uses Apple Vision entirely on the device. The optional Academic workflow improves mathematical notes with cloud vision models and creates editable Markdown and LaTeX plus a navigable semantic PDF.

## Features

- Capture pages with the camera, import photos, or import PDFs.
- On-device English and Simplified Chinese OCR with Apple Vision.
- Searchable local library, OCR overlays, manual corrections, and PDF reading.
- Academic math-note reconstruction with request-level progress and resumable checkpoints.
- Academic exports: Markdown, LaTeX, standalone HTML, semantic PDF, source-page facsimile PDF, evidence JSON, extracted figures, and a ZIP bundle.
- Conditional in-document Contents block for Academic exports when the editable Markdown contains headings.
- Local HTML + MathML rendering through WebKit; no remote renderer or CDN is required.

## Privacy at a glance

| Workflow | Leaves the device? | Stored where? |
| --- | --- | --- |
| Library / Import OCR | No | App sandbox on the device |
| Academic OCR | Yes, after an explicit confirmation | Confirmed pages are sent to Mistral and SiliconFlow; job files remain in the app sandbox |
| Academic rendering | No | HTML, MathML, PDF, LaTeX, and ZIP are generated locally |
| Sharing / saving | Only when you choose a system share or save action | Destination selected by you |

Deleting a document removes its associated local files. Provider retention, quota, and privacy terms apply to Academic uploads.

## API-key safety

The repository contains only [`ProviderKeys.example.plist`](VisionNotes/Resources/ProviderKeys.example.plist), whose values are empty. Your real `ProviderKeys.plist` is ignored by Git and must never be committed, pasted into source code, logs, screenshots, issues, or build artifacts that you publish.

Create your local configuration:

```sh
cp VisionNotes/Resources/ProviderKeys.example.plist \
   VisionNotes/Resources/ProviderKeys.plist
```

Then enter `MistralAPIKey` and `SiliconFlowAPIKey` in the local file. A build step copies the local file into the app bundle; when it is absent, the empty example is copied so a clean clone still compiles. The ordinary on-device workflow does not need either key.

> Important: secrets embedded in an iOS app can be extracted by someone who receives the app. Direct provider calls are suitable for local development, not for distributing a production app with privileged keys. For a public/TestFlight/App Store release, put provider calls behind a server-side proxy, restrict quotas, and rotate any key that may already have been shared.

## Requirements

- macOS with Xcode 15.4 or later
- iOS 17 or later
- Mistral and SiliconFlow API keys only for Academic OCR

No third-party Swift package is required.

## Run

1. Open `VisionNotes.xcodeproj` in Xcode.
2. Select the **VisionNotes** scheme and an iPhone Simulator or device.
3. Press Run.
4. Use **Load Demo Notes** in the Library to explore the on-device workflow without private files.

No signing team is required for the Simulator. For a physical device, select your own team under Signing & Capabilities.

## How the two OCR paths work

### Library / Import

Apple Vision normalizes each page, recognizes supported English and Chinese text, sorts observations into reading order, and stores searchable text and bounding boxes locally. Imported PDFs are processed page by page to keep memory usage bounded.

### Academic

After the upload disclosure is accepted, normalized pages are sent to Mistral for base OCR and to SiliconFlow for mathematical vision correction. Completed requests are checkpointed, so Resume reuses finished work. Semantic reconstruction turns the evidence into structured Markdown and LaTeX, while a restricted local WebKit document renders HTML + MathML into PDF.

Academic OCR is probabilistic. Review `[unclear: ...]` markers and compare important formulas with the facsimile PDF before relying on the result.

### Table of contents behavior

The table of contents is conditional; it is not inferred from ordinary prose or equations. The renderer scans the editable Markdown for ATX headings (`#` through `####`).

- If at least one heading exists, the standalone HTML and the WebKit-generated semantic PDF include a visible **Contents** block at the beginning.
- If no Markdown headings exist, no Contents block is generated.
- Vision Notes does not currently create a native PDF outline or bookmark tree, so PDF viewers will not show a section sidebar.
- The HTML entries link to heading anchors. WebKit does not guarantee that those links are retained as native PDF link annotations on every iOS version, so clickable navigation is reliable in the standalone HTML but is not guaranteed in `document.pdf`.
- `document.tex` always includes `\tableofcontents`, but the bundled `document.pdf` is generated from HTML + MathML rather than compiled from that TeX source.

To force a visible Contents block, open **Source**, add headings such as `# Topic` and `## Section`, then tap **Recompile locally**.

## Project structure

```text
VisionNotes/
├── App/             app entry point and tab navigation
├── MathNotes/       Academic pipeline, models, rendering, and UI
├── Models/          SwiftData document and OCR models
├── Persistence/     model-container setup and document store
├── Resources/       assets and the tracked empty key example
├── Services/        OCR, importing, storage, and demo data
├── Utilities/       reading order, search, coordinates, and naming
├── ViewModels/      Library, Import, and Search state
└── Views/           Library, Import, Search, readers, and editor
VisionNotesTests/    unit and integration tests
VisionNotesUITests/  simulator smoke tests
```

## Tests

In Xcode, press `Command-U`, or run:

```sh
xcodebuild test \
  -project VisionNotes.xcodeproj \
  -scheme VisionNotes \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

The tests cover local OCR utilities, search, storage, Academic parsing and rendering, job checkpoints, and UI smoke flows. Tests do not require committed provider credentials.

## Known limitations

- Handwritten and mathematical OCR can misread symbols, diagrams, and uncommon notation.
- Semantic reconstruction preserves meaning and hierarchy, not arbitrary handwritten placement.
- The local MathML converter covers common notation; uncommon LaTeX packages may render literally while remaining in `document.tex`.
- Native PDF outlines and bookmarks are not generated; the Contents block is conditional on Markdown headings.
- The library is local only; there is no account or cloud sync.
- Direct client-side provider keys are not safe for a production distribution.

More implementation and privacy details are in [`ACADEMIC_OCR.md`](ACADEMIC_OCR.md).
