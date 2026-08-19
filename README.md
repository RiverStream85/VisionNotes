# Vision Notes

<p align="center">
  <img src="VisionNotes/Resources/Assets.xcassets/AppIcon.appiconset/VisionNotesAppIcon.png" alt="Vision Notes logo: a green V formed from folded note pages" width="180">
</p>

Vision Notes is an iOS notebook for scanning, recognizing, searching, and exporting notes. Library OCR and the Academic handwritten-math workflow run on the device by default. Mistral OCR and Qwen3-VL remain available only as an explicitly authorized fallback.

## Features

- Capture pages with the camera, import photos, or import PDFs.
- On-device English and Simplified Chinese OCR with Apple Vision.
- Searchable local library, OCR overlays, manual corrections, and PDF reading.
- On-device Firebird handwritten-math reconstruction with resumable encrypted checkpoints.
- Academic exports: Markdown, LaTeX, standalone HTML, semantic PDF, source-page facsimile PDF, evidence JSON, extracted figures, and a ZIP bundle.
- Conditional in-document Contents block when editable Markdown contains headings.
- Local HTML + MathML rendering through WebKit; no remote renderer or CDN.

## Default behavior and privacy

| Workflow | Default network behavior | Persistent storage |
| --- | --- | --- |
| Library / Import OCR | Never leaves the device | Note files are CryptoKit AES-GCM envelopes in the app container |
| Academic reconstruction | Firebird runs locally | Pages, checkpoints, edits, and exports are AES-GCM envelopes |
| Firebird model | No download at cold start | Weights are provisioned into the app container and AES-GCM sealed |
| Cloud fallback | Off; requires the user to select **Allow cloud fallback** for that job | Optional provider credentials live in ThisDeviceOnly Keychain items |
| Academic rendering | Never leaves the device | HTML, MathML, PDF, LaTeX, and ZIP are generated locally, then sealed |
| Sharing / saving | Only after a system share/save action | Destination selected by the user |

The 256-bit content key is never written to source, plist files, logs, manifests, or exports. On physical devices it is wrapped through a non-exportable Secure Enclave P-256 agreement key; simulators use a `ThisDeviceOnly` Keychain item. Plain files are materialized under the protected process temporary directory only while a reader, renderer, or share sheet needs them.

## On-device Firebird path

Cold start does not contact a model host. `FirebirdWeightStore` creates or opens the encrypted Firebird weight file under `Application Support/VisionNotes/Models/Firebird`. Academic pages first produce local Apple Vision layout evidence. The Firebird decoder then processes the evidence token by token and reconstructs Markdown/LaTeX math.

`FirebirdFusedKernel.metal` is a custom Metal shader, not a wrapper around MPS or a system GEMM. For each decode token it performs the following in one GPU dispatch:

1. RMSNorm.
2. Q/K/V matrix-vector projection.
3. RoPE on query and key pairs.
4. KV-cache update, attention scores and softmax.
5. Attention-value GEMM.

The Swift decode loop issues exactly one `dispatchThreadgroups` call per token through this fused kernel, keeping the decode path on Apple silicon.

## Opt-in cloud fallback

The original cloud clients are retained for difficult pages. Choosing **Process on this iPhone** records no cloud consent and the pipeline cannot call Mistral or Qwen3-VL. Choosing **Allow cloud fallback** records consent in that job manifest; the clients are reached only if local Firebird reconstruction fails.

Provider credentials are not bundled. Development or host code can provision them with `CloudProviderCredentialStore.save(_:for:)`; they are saved as `ThisDeviceOnly` Keychain items. A production distribution should still use a scoped server-side proxy and per-user quotas rather than ship privileged provider credentials.

## Requirements

- macOS with Xcode 15.4 or later
- iOS 17 or later
- An Apple-silicon iPhone or iPad for the fused Metal decode path
- No cloud credentials for the default workflow
- Optional Mistral and SiliconFlow/Qwen3-VL credentials only for the opt-in fallback

No third-party Swift package is required. The Metal Toolchain Xcode component must be installed to compile the `.metal` source.

## Run

1. Open `VisionNotes.xcodeproj` in Xcode.
2. Select the **VisionNotes** scheme and an iPhone Simulator or device.
3. Press Run.
4. Use **Load Demo Notes** to explore the library without private files.
5. In **Academic**, scan or import pages and choose the local default or the explicitly labeled cloud fallback.

No signing team is required for the Simulator. For a physical device, select your own team under Signing & Capabilities.

## Academic exports

Firebird output remains editable. **Recompile locally** rebuilds Markdown, LaTeX, offline HTML, semantic PDF, facsimile PDF and the ZIP archive without contacting an OCR provider. The semantic PDF uses restricted local HTML + MathML in WebKit; `document.tex` is separate, human-readable XeLaTeX-compatible source.

The Contents block is conditional. HTML and the semantic PDF include it only when the editable Markdown contains ATX headings (`#` through `####`). The app does not create a native PDF bookmark tree, and WebKit does not guarantee that HTML anchors become native PDF link annotations on every iOS version.

## Project structure

```text
VisionNotes/
├── App/             app entry point and tab navigation
├── MathNotes/       Firebird, fused Metal, fallback clients, rendering, and UI
├── Models/          SwiftData document and OCR models
├── Persistence/     model-container setup and document store
├── Resources/       app assets; no credentials or content keys
├── Security/        Secure Enclave/Keychain key management and AES-GCM vault
├── Services/        OCR, importing, encrypted file storage, and demo data
├── Utilities/       reading order, search, coordinates, and naming
├── ViewModels/      Library, Import, Search, and Academic state
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

Tests cover local OCR utilities, search, AES-GCM round trips and tamper rejection, encrypted file/job storage, Academic parsing and rendering, job checkpoints, and UI smoke flows. Tests do not require cloud credentials.

## Known limitations

- Handwritten and mathematical OCR remains probabilistic; compare important formulas with the facsimile PDF.
- Semantic reconstruction preserves meaning and hierarchy, not arbitrary handwritten placement.
- The local MathML converter covers common notation; uncommon LaTeX packages may render literally while remaining in `document.tex`.
- Native PDF outlines and bookmarks are not generated.
- The library is local only; there is no account or cloud sync.
- Firebird weights are provisioned with the app build. Updating the model requires an app/model migration; the app never silently downloads replacement weights.

More implementation and privacy details are in [`ACADEMIC_OCR.md`](ACADEMIC_OCR.md).
