import SwiftData
import SwiftUI

/// Full-page image reader: pinch to zoom, drag to pan, optional OCR overlay.
@MainActor
struct ImageReaderView: View {
    let document: LibraryDocument
    var highlightTerms: [String] = []

    @Environment(\.modelContext) private var modelContext

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var errorAlert: ErrorAlert?
    @State private var showsBoxes = true
    @State private var selectedBlockText: String?
    @State private var showsEditor = false

    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gestureOffset: CGSize = .zero

    private var page: DocumentPage? { document.sortedPages.first }

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            Divider()
            textPanel
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showsBoxes) {
                        Label("Show Text Boxes", systemImage: "square.dashed")
                    }
                    Button {
                        showsEditor = true
                    } label: {
                        Label("Edit OCR Text", systemImage: "square.and.pencil")
                    }
                    .disabled(page == nil)
                    Button {
                        resetZoom()
                    } label: {
                        Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("imageReaderMenu")
            }
        }
        .sheet(isPresented: $showsEditor) {
            if let page {
                OCRTextEditorView(page: page, document: document)
            }
        }
        .alert("Recognized text", isPresented: selectedBlockBinding) {
            Button("OK", role: .cancel) { selectedBlockText = nil }
        } message: {
            Text(selectedBlockText ?? "")
        }
        .errorAlert($errorAlert)
        .task(id: page?.imageFileName) { await loadImage() }
    }

    // MARK: - Image

    private var imageArea: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.systemBackground)

                if let image {
                    let containerSize = proxy.size
                    let imageSize = image.size
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: containerSize.width, height: containerSize.height)

                        if showsBoxes {
                            boxOverlay(imageSize: imageSize, containerSize: containerSize)
                        }
                    }
                    .frame(width: containerSize.width, height: containerSize.height)
                    .scaleEffect(currentScale)
                    .offset(currentOffset)
                    .gesture(zoomGesture.simultaneously(with: panGesture))
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel("Page image. Double tap to zoom.")
                } else if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("The local file for this document is missing. Delete it and import the image again.")
                    }
                }
            }
            .clipped()
        }
        .frame(maxHeight: .infinity)
    }

    private func boxOverlay(imageSize: CGSize, containerSize: CGSize) -> some View {
        ForEach(page?.sortedTextBlocks ?? []) { block in
            let rect = BoundingBoxConverter.displayRect(
                normalized: block.normalizedBoundingBox,
                imageSize: imageSize,
                containerSize: containerSize
            )
            Rectangle()
                .fill(Color.yellow.opacity(0.18))
                .overlay(Rectangle().stroke(Color.orange.opacity(0.9), lineWidth: 1))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .onTapGesture { selectedBlockText = block.text }
                .accessibilityLabel(block.text)
        }
    }

    // MARK: - Text panel

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recognized text")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let page, !page.textBlocks.isEmpty {
                    Text("\(page.textBlocks.count) blocks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showsEditor = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                        .font(.caption)
                }
                .disabled(page == nil)
                .accessibilityIdentifier("editOCRTextButton")
            }

            ScrollView {
                if let text = page?.recognizedText, !text.isEmpty {
                    HighlightedBodyText(text: text, terms: highlightTerms, font: .callout)
                } else {
                    Text(document.processingStatus == .processing
                         ? "Recognizing text…"
                         : "No text was recognized on this page.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 180)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Gestures

    private var currentScale: CGFloat {
        min(max(scale * gestureScale, 1), 6)
    }

    private var currentOffset: CGSize {
        CGSize(
            width: offset.width + gestureOffset.width,
            height: offset.height + gestureOffset.height
        )
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($gestureScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                scale = min(max(scale * value.magnification, 1), 6)
                if scale == 1 { offset = .zero }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($gestureOffset) { value, state, _ in
                guard scale > 1 else { return }
                state = value.translation
            }
            .onEnded { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1 {
                resetZoom()
            } else {
                scale = 2.5
            }
        }
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
    }

    // MARK: - Loading

    private var selectedBlockBinding: Binding<Bool> {
        Binding(
            get: { selectedBlockText != nil },
            set: { if !$0 { selectedBlockText = nil } }
        )
    }

    /// Reads the file off the main actor: only `Sendable` values (a file name
    /// and a directory) cross the task boundary, never the SwiftData model.
    private func loadImage() async {
        guard let page, let fileName = page.imageFileName else {
            isLoading = false
            return
        }
        let directory = PageImageLocator.directory(for: document.documentType)
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try FileStorageService.shared.data(forFileName: fileName, in: directory)
            }.value
            guard let loaded = UIImage(data: data) else {
                throw AppError.photoLoadFailed
            }
            image = loaded
        } catch {
            image = nil
            errorAlert = ErrorAlert(error)
        }
    }
}
