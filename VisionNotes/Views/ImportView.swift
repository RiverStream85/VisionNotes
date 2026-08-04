import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ImportView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel = ImportViewModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var showsFileImporter = false
    @State private var showsCamera = false
    @State private var capturedImage: CapturedImage?
    @State private var cameraAlert: ErrorAlert?
    @State private var isLoadingPhoto = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.isImporting || viewModel.stage == .complete {
                        ImportProgressCard(
                            stage: viewModel.stage ?? .preparingFile,
                            progress: viewModel.progress,
                            completedTitle: viewModel.lastImportedTitle,
                            onCancel: viewModel.cancel,
                            onDone: viewModel.dismissCompletion
                        )
                    }

                    importOptions
                    footnote
                }
                .padding()
            }
            .navigationTitle("Import")
            .photosPicker(
                isPresented: $showsPhotoPicker,
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [UTType.pdf],
                allowsMultipleSelection: false
            ) { result in
                handlePDFSelection(result)
            }
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { image in
                    capturedImage = CapturedImage(image: image)
                }
            }
            .sheet(item: $capturedImage) { preview in
                CapturePreviewView(
                    image: preview.image,
                    onSave: {
                        viewModel.importCameraPhoto(preview.image, modelContext: modelContext)
                        capturedImage = nil
                    },
                    onRetake: {
                        capturedImage = nil
                        showsCamera = true
                    },
                    onCancel: { capturedImage = nil }
                )
            }
            .onChange(of: photoItem) { _, newValue in
                guard let newValue else { return }
                loadPhoto(newValue)
            }
            .errorAlert($viewModel.errorAlert)
            .errorAlert($cameraAlert)
        }
    }

    // MARK: - Options

    private var importOptions: some View {
        VStack(spacing: 14) {
            ImportOptionButton(
                title: "Take Photo",
                subtitle: CameraAccess.isCameraAvailable
                    ? "Capture a page, whiteboard, or handwritten note."
                    : "Not available on this device or in the Simulator.",
                systemImage: "camera",
                isEnabled: CameraAccess.isCameraAvailable && !viewModel.isImporting,
                action: startCameraCapture
            )
            .accessibilityIdentifier("takePhotoButton")

            ImportOptionButton(
                title: "Import Photo",
                subtitle: "Pick a JPEG, PNG, or HEIC image from your library.",
                systemImage: "photo.on.rectangle",
                isEnabled: !viewModel.isImporting && !isLoadingPhoto,
                action: { photoItem = nil; showsPhotoPicker = true }
            )
            .accessibilityIdentifier("importPhotoButton")

            ImportOptionButton(
                title: "Import PDF",
                subtitle: "Every page is rendered and recognized one at a time.",
                systemImage: "doc.badge.plus",
                isEnabled: !viewModel.isImporting,
                action: { showsFileImporter = true }
            )
            .accessibilityIdentifier("importPDFButton")
        }
    }

    private var footnote: some View {
        VStack(spacing: 6) {
            Label("Text recognition runs on this device", systemImage: "lock.shield")
                .font(.footnote)
            Text("Nothing is uploaded, and no network connection or API key is needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    @State private var showsPhotoPicker = false

    /// Wraps the capture so the preview sheet has a stable identity.
    private struct CapturedImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private func startCameraCapture() {
        switch CameraAccess.state {
        case .authorized:
            showsCamera = true
        case .notDetermined:
            Task {
                let state = await CameraAccess.requestAccess()
                if state == .authorized {
                    showsCamera = true
                } else {
                    cameraAlert = ErrorAlert(AppError.cameraPermissionDenied)
                }
            }
        case .denied:
            cameraAlert = ErrorAlert(
                title: AppError.cameraPermissionDenied.errorDescription ?? "No camera access",
                message: AppError.cameraPermissionDenied.recoverySuggestion ?? ""
            )
        case .unavailable:
            cameraAlert = ErrorAlert(AppError.cameraUnavailable)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        isLoadingPhoto = true
        Task {
            defer {
                isLoadingPhoto = false
                photoItem = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    viewModel.errorAlert = ErrorAlert(AppError.photoLoadFailed)
                    return
                }
                let fileName = item.supportedContentTypes.first?.preferredFilenameExtension.map {
                    "Photo.\($0)"
                }
                viewModel.importPhoto(data: data, fileName: fileName, modelContext: modelContext)
            } catch {
                viewModel.errorAlert = ErrorAlert(AppError.photoLoadFailed)
            }
        }
    }

    private func handlePDFSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            viewModel.importPDF(from: url, modelContext: modelContext)
        case .failure:
            viewModel.errorAlert = ErrorAlert(
                title: "The PDF could not be opened.",
                message: "Try another file, or copy it into the Files app first."
            )
        }
    }
}

// MARK: - Building blocks

private struct ImportOptionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct ImportProgressCard: View {
    let stage: ImportStage
    let progress: Double
    let completedTitle: String?
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(stage == .complete ? "Import complete" : "Importing…")
                    .font(.headline)
                Spacer()
                if stage == .complete {
                    Button("Done", action: onDone)
                } else {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .accessibilityIdentifier("cancelImportButton")
                }
            }

            ProgressView(value: max(min(progress, 1), 0))
                .progressViewStyle(.linear)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ImportStage.allCases) { item in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: item))
                            .foregroundStyle(color(for: item))
                            .frame(width: 18)
                        Text(item.displayName)
                            .font(.subheadline)
                            .foregroundStyle(item.rawValue <= stage.rawValue ? .primary : .secondary)
                    }
                }
            }

            if stage == .complete, let completedTitle {
                Text("Saved “\(completedTitle)” to your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("importProgressCard")
    }

    private func symbol(for item: ImportStage) -> String {
        if item.rawValue < stage.rawValue { return "checkmark.circle.fill" }
        if item == stage { return stage == .complete ? "checkmark.circle.fill" : "circle.dotted" }
        return "circle"
    }

    private func color(for item: ImportStage) -> Color {
        item.rawValue < stage.rawValue || stage == .complete ? .green : .secondary
    }
}

/// Preview shown after a capture: nothing is saved until the user confirms.
private struct CapturePreviewView: View {
    let image: UIImage
    let onSave: () -> Void
    let onRetake: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
                Text("Save this capture to your library and recognize its text?")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Retake") {
                        onRetake()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ImportView()
        .modelContainer(ModelContainerProvider.makeContainer(inMemory: true).container)
}
