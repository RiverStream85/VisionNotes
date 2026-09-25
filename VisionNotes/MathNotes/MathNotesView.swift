import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

@MainActor
struct MathNotesView: View {
    @State private var viewModel = MathNotesViewModel()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var showsScanner = false
    @State private var confirmsUpload = false
    @State private var confirmsDeleteAll = false

    var body: some View {
        dialogLayer
            .alert("Academic conversion", isPresented: errorBinding) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
    }

    private var dialogLayer: some View {
        importLayer
            .confirmationDialog(
                "Process \(viewModel.draftPages.count) pages on this iPhone?",
                isPresented: $confirmsUpload,
                titleVisibility: .visible
            ) {
                Button("Process on this iPhone") {
                    viewModel.startConversion()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Processing starts on this device and uploads nothing. If the local reconstruction package is unavailable or cannot finish, the saved job pauses before offering a separately confirmed cloud fallback.")
            }
            .alert("Delete all Academic jobs?", isPresented: $confirmsDeleteAll) {
                Button("Delete all", role: .destructive) { viewModel.deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes source pages, OCR evidence and every export from the app container.")
            }
    }

    private var importLayer: some View {
        navigationLayer
            .photosPicker(
                isPresented: $showsPhotos,
                selection: $photoItems,
                maxSelectionCount: 20,
                matching: .images,
                photoLibrary: .shared()
            )
            .fileImporter(
                isPresented: $showsFiles,
                allowedContentTypes: [UTType.pdf, UTType.image],
                allowsMultipleSelection: false,
                onCompletion: handleFileImport
            )
            .fullScreenCover(isPresented: $showsScanner, content: scannerContent)
            .onChange(of: photoItems) { _, items in loadPhotoItems(items) }
            .onReceive(NotificationCenter.default.publisher(for: FirebirdModelDownloader.progressDidChange)) { _ in
                viewModel.refreshModelStatus()
            }
            .task {
                viewModel.refreshModelStatus()
                viewModel.refreshCloudCredentialStatus()
                await viewModel.loadJobs()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .visionNotesWillSuspendPlaintext)
            ) { _ in
                viewModel.suspendForProtectedLifecycle()
            }
    }

    private var navigationLayer: some View {
        NavigationStack {
            academicList
                .navigationTitle("Academic")
                .toolbar { academicToolbar }
        }
    }

    @ToolbarContentBuilder
    private var academicToolbar: some ToolbarContent {
        if !viewModel.draftPages.isEmpty {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        if !viewModel.jobs.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete all jobs", role: .destructive) { confirmsDeleteAll = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Academic job actions")
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first { viewModel.importFile(url) }
        case .failure:
            viewModel.errorMessage = "The selected file could not be opened."
        }
    }

    private func scannerContent() -> some View {
        DocumentScannerView(
            onComplete: { images in
                showsScanner = false
                viewModel.addScannedImages(images)
            },
            onCancel: { showsScanner = false },
            onFailure: { _ in
                showsScanner = false
                viewModel.errorMessage = "The document scanner could not finish."
            }
        )
        .ignoresSafeArea()
    }

    private var academicList: some View {
        List {
            modelSection
            newDocumentSection
            savedJobsSection
            credentialsSection
            privacySection
        }
    }

    private var newDocumentSection: some View {
        Section {
            TextField("Document title (optional)", text: $viewModel.draftTitle)
                .textInputAutocapitalization(.words)
            sourceButtons
            if viewModel.isPreparingDraft {
                HStack {
                    ProgressView()
                    Text("Preparing pages on this device…").foregroundStyle(.secondary)
                }
            }
            if !viewModel.draftPages.isEmpty {
                ForEach(Array(viewModel.draftPages.enumerated()), id: \.element.id) { index, page in
                    draftRow(page: page, number: index + 1)
                }
                .onMove(perform: viewModel.moveDraftPages)
                .onDelete(perform: viewModel.deleteDraftPages)
                Button { confirmsUpload = true } label: {
                    Label(
                        "Create Academic document (\(viewModel.draftPages.count) pages)",
                        systemImage: "function"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking)
                .accessibilityHint("Starts a local-only reconstruction attempt")
            }
        } header: {
            Text("New Academic document")
        } footer: {
            Text("Drag with Edit to reorder. Rotate or swipe to delete before processing. The normalized pages saved here remain untouched by later reconstruction.")
        }
    }

    private var modelSection: some View {
        Section {
            switch viewModel.modelStatus {
            case .checking:
                ProgressView()
            case .ready:
                Label("On-device model ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .notDownloaded:
                Button {
                    viewModel.downloadModel()
                } label: {
                    Label("Download model (1.8 GB, Wi-Fi)", systemImage: "arrow.down.circle")
                }
            case .downloading(let received, let total):
                VStack(alignment: .leading, spacing: 6) {
                    if total > 0 {
                        ProgressView(value: Double(received), total: Double(total))
                        Text("\(Self.byteFormatter.string(fromByteCount: received)) of \(Self.byteFormatter.string(fromByteCount: total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            case .failed:
                Button {
                    viewModel.downloadModel()
                } label: {
                    Label("Download failed · Retry", systemImage: "exclamationmark.arrow.circlepath")
                }
            }
        } header: {
            Text("On-device model")
        } footer: {
            Text("Qwen3-VL-2B (4-bit). The download continues while the screen is locked or the app is in the background. Only public model files are downloaded; no pages are uploaded.")
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var savedJobsSection: some View {
        Section("Saved jobs") {
            if viewModel.jobs.isEmpty {
                ContentUnavailableView(
                    "No Academic jobs",
                    systemImage: "doc.text.image",
                    description: Text("Scan handwritten math notes to build editable source and local documents.")
                )
            } else {
                ForEach(viewModel.jobs) { job in
                    NavigationLink {
                        MathNoteJobDetailView(viewModel: viewModel, jobID: job.id)
                    } label: {
                        jobRow(job)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { viewModel.delete(job) }
                    }
                }
            }
        }
    }

    private var privacySection: some View {
        Section {
            Label("Academic jobs begin with on-device reconstruction.", systemImage: "iphone.gen3")
            Text("Your notes are encrypted on this iPhone. Pages are sent to cloud providers only after you choose cloud fallback and confirm the upload.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Privacy and renderer")
        } footer: {
            Text("PDF: on-device HTML + MathML through WebKit, not XeLaTeX. The separate .tex file is editable XeLaTeX-oriented source.")
        }
    }

    private var credentialsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mistral API key").font(.headline)
                SecureField("Enter a new Mistral key", text: $viewModel.mistralCredentialDraft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    credentialStatus(saved: viewModel.hasMistralCredential)
                    Spacer()
                    Button("Save") { viewModel.saveMistralCredential() }
                        .disabled(viewModel.mistralCredentialDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if viewModel.hasMistralCredential {
                        Button("Remove", role: .destructive) { viewModel.removeMistralCredential() }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Qwen3-VL / SiliconFlow API key").font(.headline)
                SecureField("Enter a new SiliconFlow key", text: $viewModel.qwen3VLCredentialDraft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    credentialStatus(saved: viewModel.hasQwen3VLCredential)
                    Spacer()
                    Button("Save") { viewModel.saveQwen3VLCredential() }
                        .disabled(viewModel.qwen3VLCredentialDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if viewModel.hasQwen3VLCredential {
                        Button("Remove", role: .destructive) { viewModel.removeQwen3VLCredential() }
                    }
                }
            }

            if let message = viewModel.credentialStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Cloud fallback keys")
        } footer: {
            Text("Bring your own keys. Saved values are never shown again and are consulted only after local Firebird failure plus a separate per-job upload confirmation.")
        }
    }

    private func credentialStatus(saved: Bool) -> some View {
        Label(saved ? "Saved on this device" : "Not saved", systemImage: saved ? "checkmark.shield" : "key")
            .font(.caption)
            .foregroundStyle(saved ? .green : .secondary)
    }

    private var sourceButtons: some View {
        HStack(spacing: 10) {
            Button {
                showsScanner = true
            } label: {
                Label("Scan", systemImage: "doc.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!VNDocumentCameraViewController.isSupported || viewModel.isWorking)

            Button {
                photoItems = []
                showsPhotos = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isWorking)

            Button {
                showsFiles = true
            } label: {
                Label("Files", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isWorking)
        }
        .labelStyle(.titleAndIcon)
    }

    private func draftRow(page: MathNoteDraftPage, number: Int) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = page.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 62, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Page \(number)").font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(page.data.count), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { viewModel.rotateDraftPage(page.id) } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Rotate page \(number) clockwise")
        }
    }

    private func jobRow(_ job: MathNoteJobManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title).font(.headline).lineLimit(1)
                Spacer()
                if viewModel.activeJobID == job.id, viewModel.isWorking { ProgressView() }
            }
            HStack(spacing: 8) {
                Label("\(job.pageCount)", systemImage: "doc.on.doc")
                Text(job.stage.displayName)
                if job.uncertainCount > 0 {
                    Label("\(job.uncertainCount) unclear", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if job.stage != .complete && job.stage != .failed && job.stage != .cancelled {
                if job.stage == .refining {
                    ProgressView()
                } else {
                    ProgressView(value: job.displayedProgress)
                }
                if let detail = job.stageDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private func loadPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var data: [Data] = []
            for item in items {
                if let value = try? await item.loadTransferable(type: Data.self) { data.append(value) }
            }
            photoItems = []
            if data.isEmpty { viewModel.errorMessage = "The selected photos could not be read." }
            else { viewModel.addRawImageData(data) }
        }
    }
}

@MainActor
private struct MathNoteJobDetailView: View {
    @Bindable var viewModel: MathNotesViewModel
    let jobID: UUID

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var mode = DetailMode.preview
    @State private var confirmsDelete = false
    @State private var confirmsCloudFallback = false

    enum DetailMode: String, CaseIterable, Identifiable {
        case preview = "Compare"
        case source = "Source"
        var id: Self { self }
    }

    var body: some View {
        Group {
            if let job = viewModel.selectedJob, job.id == jobID {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusCard(job)
                        if job.stage == .complete {
                            Button {
                                viewModel.rebuildSelected()
                            } label: {
                                Label("Recompile locally", systemImage: "hammer")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                viewModel.isWorking ||
                                viewModel.selectedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                            Text("Rebuilds the WebKit PDF, LaTeX, HTML and ZIP from the saved source without contacting OCR providers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("View", selection: $mode) {
                                ForEach(DetailMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            if viewModel.selectedJobDirectory == nil && viewModel.isWorking {
                                ProgressView("Opening saved result…")
                            } else if mode == .preview { comparison(job) }
                            else { sourceEditor(job) }

                            exportActions(job)
                        } else if job.stage == .awaitingCloudConsent, !viewModel.isWorking {
                            cloudFallbackActions(job)
                        } else if !viewModel.isWorking {
                            Button {
                                viewModel.resume(job)
                            } label: {
                                Label("Resume from saved stages", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isWorking)
                        }
                    }
                    .padding()
                }
                .navigationTitle(job.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete Academic job")
                    }
                }
                .alert("Delete this Academic job?", isPresented: $confirmsDelete) {
                    Button("Delete", role: .destructive) { viewModel.delete(job) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the source pages, evidence and exports from the app.")
                }
                .confirmationDialog(
                    "Use cloud fallback for this job?",
                    isPresented: $confirmsCloudFallback,
                    titleVisibility: .visible
                ) {
                    Button("Upload and resume") { viewModel.useCloudFallback(job) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The complete rasterized PDF is sent to Mistral OCR. Each page overview and high-resolution crop is sent in a separate request to Qwen3-VL through SiliconFlow. A final Qwen3-VL request receives those transcripts with Mistral-derived text for merging. This one-shot authorization is consumed before upload; provider privacy, retention, and quota terms apply.")
                }
            } else {
                ProgressView("Opening saved job…")
            }
        }
        .task(id: jobID) { await viewModel.selectJob(jobID) }
        .onReceive(
            NotificationCenter.default.publisher(for: .visionNotesDidResumePlaintext)
        ) { _ in
            Task { await viewModel.selectJob(jobID) }
        }
        .onDisappear { viewModel.releaseMaterializedPreview(for: jobID) }
    }

    private func statusCard(_ job: MathNoteJobManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(job.stage.displayName, systemImage: statusIcon(job.stage))
                    .font(.headline)
                Spacer()
                Text("\(job.pageCount) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if job.stage != .complete && viewModel.activeJobID == job.id && viewModel.isWorking {
                ProgressView(value: job.displayedProgress)
                HStack {
                    Text(job.stageDetail ?? "Working…")
                    Spacer()
                    if job.stage != .refining {
                        Text("\(Int((job.displayedProgress * 100).rounded()))%")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("iOS may pause this work in the background. Every completed stage is saved and can resume safely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel and keep progress", role: .cancel) { viewModel.cancel() }
            } else if job.stage == .awaitingCloudConsent {
                Text("Local reconstruction stopped. Any completed checkpoints were preserved and nothing was uploaded; choose a local retry or review the cloud disclosure below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if job.stage != .complete {
                Text("This job is paused. Resume uses every completed local checkpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = job.failureMessage {
                Text(failure).font(.subheadline).foregroundStyle(.red)
            }
            if job.uncertainCount > 0 {
                Label("\(job.uncertainCount) uncertain spans need review", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(job.rendererDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func cloudFallbackActions(_ job: MathNoteJobManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                viewModel.resume(job)
            } label: {
                Label("Retry on this iPhone", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                confirmsCloudFallback = true
            } label: {
                Label("Use cloud fallback…", systemImage: "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if !viewModel.hasMistralCredential || !viewModel.hasQwen3VLCredential {
                Text("Save both bring-your-own cloud keys in the Academic screen before using the fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func comparison(_ job: MathNoteJobManifest) -> some View {
        let sourcePages = viewModel.sourcePageURLs()
        let renderedURL = viewModel.artifactURL(job.artifacts.pdf)
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 14) {
                SourcePagesPreview(urls: sourcePages)
                    .frame(maxWidth: .infinity)
                WebKitPDFPreview(url: renderedURL)
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 640)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Photographed source", systemImage: "photo")
                    .font(.headline)
                SourcePagesPreview(urls: sourcePages)
                    .frame(height: 390)
                Label("WebKit reconstruction", systemImage: "doc.richtext")
                    .font(.headline)
                WebKitPDFPreview(url: renderedURL)
                    .frame(height: 520)
            }
        }
    }

    private func sourceEditor(_ job: MathNoteJobManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Editable Markdown + LaTeX math")
                .font(.headline)
            TextEditor(text: Binding(
                get: { viewModel.selectedSource },
                set: { value in viewModel.setSelectedSource(value) }
            ))
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 480)
            .padding(8)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
            .accessibilityLabel("Academic Markdown source")

            Button {
                viewModel.rebuildSelected()
            } label: {
                Label("Recompile locally", systemImage: "hammer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isWorking || viewModel.selectedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Recompile rebuilds Markdown, LaTeX, HTML, both PDFs and ZIP locally. Previous edits are retained in the encrypted job archive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exportActions(_ job: MathNoteJobManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share or Save").font(.headline)
            HStack {
                exportLink("WebKit PDF", image: "doc.richtext", path: job.artifacts.pdf)
                exportLink("LaTeX", image: "function", path: job.artifacts.latex)
            }
            HStack {
                exportLink("Offline HTML", image: "safari", path: job.artifacts.html)
            }
            HStack {
                exportLink("Markdown", image: "text.document", path: job.artifacts.markdown)
                exportLink("Facsimile PDF", image: "photo.on.rectangle", path: job.artifacts.facsimilePDF)
            }
            exportLink("All files ZIP", image: "archivebox", path: job.artifacts.archive)
        }
    }

    @ViewBuilder
    private func exportLink(_ title: String, image: String, path: String) -> some View {
        if let url = viewModel.artifactURL(path) {
            ShareLink(item: url) {
                Label(title, systemImage: image)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func statusIcon(_ stage: MathNoteStage) -> String {
        switch stage {
        case .complete: "checkmark.circle.fill"
        case .awaitingCloudConsent: "icloud.and.arrow.up"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "pause.circle.fill"
        default: "clock.arrow.circlepath"
        }
    }
}

private struct SourcePagesPreview: View {
    let urls: [URL]

    var body: some View {
        if urls.isEmpty {
            ContentUnavailableView("Source unavailable", systemImage: "photo.badge.exclamationmark")
        } else {
            TabView {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    Group {
                        if let data = try? Data(contentsOf: url, options: []),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ContentUnavailableView("Page unavailable", systemImage: "photo")
                        }
                    }
                    .padding(4)
                    .accessibilityLabel("Photographed source page \(index + 1) of \(urls.count)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct WebKitPDFPreview: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard let url else { view.document = nil; return }
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        uiView.document = nil
    }

    final class Coordinator {
        private var suspensionObserver: NSObjectProtocol?

        deinit {
            stopObserving()
        }

        func observe(_ view: PDFView) {
            stopObserving()
            suspensionObserver = NotificationCenter.default.addObserver(
                forName: .visionNotesWillSuspendPlaintext,
                object: nil,
                queue: .main
            ) { [weak view] _ in
                view?.document = nil
            }
        }

        func stopObserving() {
            if let suspensionObserver {
                NotificationCenter.default.removeObserver(suspensionObserver)
                self.suspensionObserver = nil
            }
        }
    }
}
