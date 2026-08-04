import SwiftData
import SwiftUI

/// Edit the recognized text of one page.
///
/// Saving updates the page immediately, so search reflects manual corrections
/// right away. Re-running OCR always asks first, because it discards edits.
@MainActor
struct OCRTextEditorView: View {
    let page: DocumentPage
    let document: LibraryDocument

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var previewImage: UIImage?
    @State private var isRunningOCR = false
    @State private var showsReOCRConfirmation = false
    @State private var errorAlert: ErrorAlert?
    @FocusState private var isEditing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                Divider()
                editor
            }
            .navigationTitle("Page \(page.pageNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancelOCREditButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isRunningOCR)
                        .accessibilityIdentifier("saveOCRTextButton")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showsReOCRConfirmation = true
                    } label: {
                        if isRunningOCR {
                            ProgressView()
                        } else {
                            Label("Run OCR Again", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isRunningOCR)
                    .accessibilityIdentifier("runOCRAgainButton")
                }
            }
            .confirmationDialog(
                "Run OCR again on this page?",
                isPresented: $showsReOCRConfirmation,
                titleVisibility: .visible
            ) {
                Button("Run OCR Again", role: .destructive) {
                    Task { await runOCRAgain() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The text below is replaced with a fresh recognition result. Any manual edits to this page are lost.")
            }
            .errorAlert($errorAlert)
            .task { await load() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .padding(.vertical, 8)
                .accessibilityLabel("Preview of page \(page.pageNumber)")
        } else {
            Color(.secondarySystemBackground)
                .frame(height: 100)
                .overlay {
                    Label("No page preview available", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recognized text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            TextEditor(text: $text)
                .font(.body)
                .focused($isEditing)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("ocrTextEditor")
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Actions

    private func load() async {
        text = page.recognizedText
        guard let fileName = page.imageFileName else { return }
        let directory = PageImageLocator.directory(for: document.documentType)
        let data = try? await Task.detached(priority: .userInitiated) {
            try FileStorageService.shared.data(forFileName: fileName, in: directory)
        }.value
        if let data {
            previewImage = UIImage(data: data)
        }
    }

    private func save() {
        do {
            try DocumentStore(modelContext: modelContext).updateRecognizedText(text, on: page)
            dismiss()
        } catch {
            errorAlert = ErrorAlert(error)
        }
    }

    private func runOCRAgain() async {
        isRunningOCR = true
        defer { isRunningOCR = false }
        do {
            let service = DocumentProcessingService(modelContext: modelContext)
            let recognized = try await service.reprocessPage(page)
            text = recognized.text
            if recognized.blocks.isEmpty {
                errorAlert = ErrorAlert(AppError.noTextRecognized)
            }
        } catch {
            errorAlert = ErrorAlert(error)
        }
    }
}
