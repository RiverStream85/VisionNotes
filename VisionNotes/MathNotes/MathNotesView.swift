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
                "Upload \(viewModel.draftPages.count) pages for Academic OCR?",
                isPresented: $confirmsUpload,
                titleVisibility: .visible
            ) {
                Button("Upload and process") { viewModel.startConversion() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pages are sent directly from this iPhone to Mistral for base OCR and SiliconFlow for mathematical correction. Results and evidence are cached locally.")
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
            .task { await viewModel.loadJobs() }
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
            newDocumentSection
            savedJobsSection
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
                .accessibilityHint("Shows a network upload confirmation before processing")
            }
        } header: {
            Text("New Academic document")
        } footer: {
            Text("Drag with Edit to reorder. Rotate or swipe to delete before upload. The normalized pages saved here remain untouched by later OCR enhancement.")
        }
    }

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
            Label("Academic OCR uploads confirmed pages to Mistral and SiliconFlow.", systemImage: "network")
            Text("The ordinary Import tab remains fully on-device. Academic jobs and exports stay in the app until you share them. Provider keys bundled for this development build can be extracted from the app; quotas and provider privacy terms apply.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Privacy and renderer")
        } footer: {
            Text("Semantic PDF: on-device HTML + MathML through WebKit, not XeLaTeX. The separate .tex file is editable and XeLaTeX-compatible.")
        }
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
                ProgressView(value: job.displayedProgress)
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
                            Text("Rebuilds the semantic PDF, LaTeX, HTML and ZIP from the saved source without contacting OCR providers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("View", selection: $mode) {
                                ForEach(DetailMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            if mode == .preview { comparison(job) }
                            else { sourceEditor(job) }

                            exportActions(job)
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
            } else {
                ProgressView("Opening saved job…")
            }
        }
        .task(id: jobID) { await viewModel.selectJob(jobID) }
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
            if viewModel.activeJobID == job.id && viewModel.isWorking {
                ProgressView(value: job.displayedProgress)
                HStack {
                    Text(job.stageDetail ?? "Working…")
                    Spacer()
                    Text("\(Int((job.displayedProgress * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("iOS may pause this work in the background. Every completed stage is saved and can resume safely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel and keep progress", role: .cancel) { viewModel.cancel() }
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

    @ViewBuilder
    private func comparison(_ job: MathNoteJobManifest) -> some View {
        let sourcePages = viewModel.sourcePageURLs()
        let semanticURL = viewModel.artifactURL(job.artifacts.pdf)
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 14) {
                SourcePagesPreview(urls: sourcePages)
                    .frame(maxWidth: .infinity)
                SemanticPDFPreview(url: semanticURL)
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 640)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Photographed source", systemImage: "photo")
                    .font(.headline)
                SourcePagesPreview(urls: sourcePages)
                    .frame(height: 390)
                Label("Semantic reconstruction", systemImage: "doc.richtext")
                    .font(.headline)
                SemanticPDFPreview(url: semanticURL)
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
                set: viewModel.setSelectedSource
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
            Text("Recompile rebuilds HTML, semantic PDF, TeX and ZIP without contacting either OCR provider. Previous edits are retained in the job archive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exportActions(_ job: MathNoteJobManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share or Save").font(.headline)
            HStack {
                exportLink("Semantic PDF", image: "doc.richtext", path: job.artifacts.pdf)
                exportLink("LaTeX", image: "function", path: job.artifacts.latex)
            }
            HStack {
                exportLink("Offline HTML", image: "safari", path: job.artifacts.html)
                exportLink("All files ZIP", image: "archivebox", path: job.artifacts.archive)
            }
            HStack {
                exportLink("Markdown", image: "text.document", path: job.artifacts.markdown)
                exportLink("Facsimile PDF", image: "photo.on.rectangle", path: job.artifacts.facsimilePDF)
            }
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
                        if let image = UIImage(contentsOfFile: url.path) {
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

private struct SemanticPDFPreview: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard let url else { view.document = nil; return }
        view.document = PDFDocument(url: url)
    }
}
