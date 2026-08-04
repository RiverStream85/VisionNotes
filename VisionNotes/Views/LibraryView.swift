import SwiftData
import SwiftUI

@MainActor
struct LibraryView: View {
    var onImportRequested: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LibraryDocument.createdAt, order: .reverse)
    private var documents: [LibraryDocument]

    @State private var viewModel = LibraryViewModel()
    @State private var renameTarget: LibraryDocument?
    @State private var renameText: String = ""
    @State private var deleteTarget: LibraryDocument?
    @State private var reprocessTarget: LibraryDocument?
    @State private var errorDetailTarget: LibraryDocument?

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("Library")
            .toolbar {
                if !documents.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onImportRequested()
                        } label: {
                            Label("Import", systemImage: "plus")
                        }
                        .accessibilityLabel("Import a new document")
                    }
                }
            }
            .sheet(item: $renameTarget) { document in
                RenameSheet(title: $renameText) { newTitle in
                    viewModel.rename(document, to: newTitle, modelContext: modelContext)
                }
            }
            .confirmationDialog(
                "Delete this document?",
                isPresented: deleteConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let deleteTarget {
                        viewModel.delete(deleteTarget, modelContext: modelContext)
                    }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("The document, its pages, its recognized text and its local files are removed.")
            }
            .confirmationDialog(
                "Run OCR again?",
                isPresented: reprocessConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Run OCR Again", role: .destructive) {
                    if let document = reprocessTarget {
                        Task { await viewModel.reprocess(document, modelContext: modelContext) }
                    }
                    reprocessTarget = nil
                }
                Button("Cancel", role: .cancel) { reprocessTarget = nil }
            } message: {
                Text("Recognized text on every page is replaced. Manual edits to this document will be lost.")
            }
            .alert(
                "Processing error",
                isPresented: errorDetailBinding,
                presenting: errorDetailTarget
            ) { _ in
                Button("OK", role: .cancel) { errorDetailTarget = nil }
            } message: { document in
                Text(document.processingError ?? "No details were recorded.")
            }
            .errorAlert($viewModel.errorAlert)
        }
    }

    // MARK: - Content

    private var documentList: some View {
        List {
            ForEach(documents) { document in
                NavigationLink {
                    DocumentReaderView(document: document)
                } label: {
                    LibraryRow(document: document)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = document
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        renameText = document.title
                        renameTarget = document
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button {
                        renameText = document.title
                        renameTarget = document
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        reprocessTarget = document
                    } label: {
                        Label("Run OCR Again", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if document.processingStatus == .failed {
                        Button {
                            errorDetailTarget = document
                        } label: {
                            Label("View Error", systemImage: "exclamationmark.triangle")
                        }
                    }
                    Button(role: .destructive) {
                        deleteTarget = document
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                viewModel.delete(at: offsets, in: documents, modelContext: modelContext)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No documents yet", systemImage: "books.vertical")
        } description: {
            Text("Capture a page with the camera, import a photo, or import a PDF. Everything is recognized on this device.")
        } actions: {
            VStack(spacing: 12) {
                Button {
                    Task { await viewModel.loadDemoNotes(modelContext: modelContext) }
                } label: {
                    if viewModel.isLoadingDemo {
                        Label("Loading…", systemImage: "sparkles")
                    } else {
                        Label("Load Demo Notes", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoadingDemo)
                .accessibilityIdentifier("loadDemoNotesButton")

                Button {
                    onImportRequested()
                } label: {
                    Label("Go to Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Bindings

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var reprocessConfirmationBinding: Binding<Bool> {
        Binding(
            get: { reprocessTarget != nil },
            set: { if !$0 { reprocessTarget = nil } }
        )
    }

    private var errorDetailBinding: Binding<Bool> {
        Binding(
            get: { errorDetailTarget != nil },
            set: { if !$0 { errorDetailTarget = nil } }
        )
    }
}

/// Rename sheet, kept separate so the text field owns its own focus state.
private struct RenameSheet: View {
    @Binding var title: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("renameTitleField")
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.height(180)])
    }

    private func save() {
        onSave(title)
        dismiss()
    }
}

#Preview {
    LibraryView(onImportRequested: {})
        .modelContainer(ModelContainerProvider.makeContainer(inMemory: true).container)
}
