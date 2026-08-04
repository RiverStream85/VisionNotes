import PDFKit
import SwiftData
import SwiftUI

/// PDF reader: PDFKit for the page itself, plus the OCR text of the current
/// page underneath, with search terms highlighted.
@MainActor
struct PDFReaderView: View {
    let document: LibraryDocument
    var initialPageNumber: Int?
    var highlightTerms: [String] = []

    @Environment(\.modelContext) private var modelContext

    @State private var currentPageNumber: Int = 1
    @State private var documentURL: URL?
    @State private var loadError: ErrorAlert?
    @State private var showsPageJump = false
    @State private var pageJumpText = ""
    @State private var showsEditor = false
    @State private var isReady = false

    private var pages: [DocumentPage] { document.sortedPages }

    private var currentPage: DocumentPage? {
        pages.first { $0.pageNumber == currentPageNumber }
    }

    var body: some View {
        VStack(spacing: 0) {
            pdfArea
            Divider()
            pageControls
            Divider()
            textPanel
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsEditor = true
                } label: {
                    Label("Edit OCR Text", systemImage: "square.and.pencil")
                }
                .disabled(currentPage == nil)
                .accessibilityIdentifier("editOCRTextButton")
            }
        }
        .sheet(isPresented: $showsEditor) {
            if let currentPage {
                OCRTextEditorView(page: currentPage, document: document)
            }
        }
        .alert("Go to page", isPresented: $showsPageJump) {
            TextField("Page number", text: $pageJumpText)
                .keyboardType(.numberPad)
            Button("Go") { jumpToTypedPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a page between 1 and \(max(document.pageCount, 1)).")
        }
        .errorAlert($loadError)
        .task { await prepare() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var pdfArea: some View {
        if let documentURL {
            PDFKitView(url: documentURL, currentPageNumber: $currentPageNumber)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isReady {
            ContentUnavailableView {
                Label("PDF unavailable", systemImage: "doc.questionmark")
            } description: {
                Text("The local file for this document is missing or could not be opened. Delete it and import the PDF again.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageControls: some View {
        HStack(spacing: 20) {
            Button {
                goToPage(currentPageNumber - 1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .disabled(currentPageNumber <= 1)
            .accessibilityIdentifier("previousPageButton")

            Button {
                pageJumpText = String(currentPageNumber)
                showsPageJump = true
            } label: {
                Text("Page \(currentPageNumber) of \(max(document.pageCount, 1))")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            .accessibilityIdentifier("pageIndicatorButton")

            Button {
                goToPage(currentPageNumber + 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .disabled(currentPageNumber >= document.pageCount)
            .accessibilityIdentifier("nextPageButton")
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recognized text · page \(currentPageNumber)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if document.processingStatus == .processing {
                    ProgressView(value: document.processingProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                }
            }

            ScrollView {
                if let text = currentPage?.recognizedText, !text.isEmpty {
                    HighlightedBodyText(text: text, terms: highlightTerms, font: .callout)
                } else {
                    Text(document.processingStatus == .processing
                         ? "This page has not been recognized yet."
                         : "No text was recognized on this page.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 170)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Actions

    private func prepare() async {
        currentPageNumber = PDFPageMapper.clampedPageNumber(
            initialPageNumber ?? 1,
            pageCount: max(document.pageCount, 1)
        ) ?? 1

        let fileName = document.localFileName
        defer { isReady = true }
        do {
            let url = try FileStorageService.shared.url(for: fileName, in: .sources)
            guard FileStorageService.shared.fileExists(fileName, in: .sources) else {
                throw AppError.fileMissing(fileName: fileName)
            }
            documentURL = url
        } catch {
            documentURL = nil
            loadError = ErrorAlert(error)
        }
    }

    private func goToPage(_ pageNumber: Int) {
        guard let clamped = PDFPageMapper.clampedPageNumber(pageNumber, pageCount: max(document.pageCount, 1)) else {
            return
        }
        currentPageNumber = clamped
    }

    private func jumpToTypedPage() {
        guard let value = Int(pageJumpText.trimmingCharacters(in: .whitespaces)) else { return }
        goToPage(value)
    }
}

/// `PDFView` wrapper that keeps the visible page in sync with a binding.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var currentPageNumber: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true)
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        context.coordinator.go(to: currentPageNumber, in: view)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
        context.coordinator.go(to: currentPageNumber, in: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPageNumber: $currentPageNumber)
    }

    final class Coordinator: NSObject {
        private let currentPageNumber: Binding<Int>
        private var observer: NSObjectProtocol?

        init(currentPageNumber: Binding<Int>) {
            self.currentPageNumber = currentPageNumber
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak view, currentPageNumber] _ in
                guard let view,
                      let document = view.document,
                      let page = view.currentPage else { return }
                let index = document.index(for: page)
                let pageNumber = PDFPageMapper.pageNumber(forIndex: index)
                if currentPageNumber.wrappedValue != pageNumber {
                    currentPageNumber.wrappedValue = pageNumber
                }
            }
        }

        /// Scrolls to a page, ignoring numbers the document does not have.
        func go(to pageNumber: Int, in view: PDFView) {
            guard let document = view.document else { return }
            let index = PDFPageMapper.pageIndex(forPageNumber: pageNumber)
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return }
            if view.currentPage != page {
                view.go(to: page)
            }
        }
    }
}
