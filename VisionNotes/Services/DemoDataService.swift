import Foundation
import SwiftData

/// The pages of the demo library, drawn before any model object is touched.
///
/// Rendering four A4-sized pages is far too slow for the main thread, so the
/// drawing happens here — a `nonisolated async` call working on plain
/// `Sendable` values — and only the finished `Data` crosses back.
struct DemoLibraryContent: Sendable {
    let lecture: DemoContentRenderer.RenderedDemoPage
    let bookPage: DemoContentRenderer.RenderedDemoPage
    let pdfData: Data
    let pdfPages: [DemoContentRenderer.RenderedDemoPage]

    static func render() async throws -> DemoLibraryContent {
        try Task.checkCancellation()
        let lecture = try DemoContentRenderer.renderImagePage(lines: lectureLines)
        let bookPage = try DemoContentRenderer.renderImagePage(lines: bookPageLines, background: .white)
        let (pdfData, pdfPages) = try DemoContentRenderer.renderPDF(pages: meetingPages)
        return DemoLibraryContent(
            lecture: lecture,
            bookPage: bookPage,
            pdfData: pdfData,
            pdfPages: pdfPages
        )
    }

    // MARK: - Page content

    static let lectureLines: [DemoContentRenderer.Line] = [
        .init("线性代数 课堂笔记", size: 52, bold: true),
        .init("Lecture 07 · Eigenvalues", size: 36, bold: true),
        .spacer(),
        .init("矩阵 A 的特征值满足 det(A - λI) = 0。"),
        .init("特征向量描述了矩阵作用下方向不变的方向。"),
        .spacer(),
        .init("Key idea: eigenvectors keep their direction.", size: 34, bold: true),
        .init("Only their length changes, by the eigenvalue."),
        .spacer(),
        .init("对称矩阵一定可以对角化。"),
        .init("Symmetric matrices always have real eigenvalues."),
        .spacer(),
        .init("作业：习题 3.4, 3.7, 3.11"),
        .init("Homework due next Tuesday.")
    ]

    static let bookPageLines: [DemoContentRenderer.Line] = [
        .init("Chapter 4 — Optical Character Recognition", size: 46, bold: true),
        .spacer(),
        .init("Optical character recognition turns pictures of text into"),
        .init("characters a computer can index and search."),
        .spacer(),
        .init("A modern recognizer works in two stages. Detection finds the"),
        .init("regions of an image that contain text. Recognition then reads"),
        .init("each region and returns a string with a confidence score."),
        .spacer(),
        .init("Reading order matters as much as accuracy: a page of correct"),
        .init("words in the wrong sequence is nearly useless for search."),
        .spacer(),
        .init("On Apple platforms the Vision framework performs both stages"),
        .init("entirely on device, so no page ever leaves the phone.")
    ]

    static let meetingPages: [[DemoContentRenderer.Line]] = [
        [
            .init("Project Vision Notes", size: 52, bold: true),
            .init("Design Review · Page 1", size: 34, bold: true),
            .spacer(),
            .init("目标：把纸质笔记变成可以搜索的文本。"),
            .init("Goal: make paper notes searchable, entirely on device."),
            .spacer(),
            .init("Scope for version one:"),
            .init("1. Camera capture and photo import."),
            .init("2. PDF import with page by page recognition."),
            .init("3. Local keyword search across every page.")
        ],
        [
            .init("Architecture Notes", size: 52, bold: true),
            .init("Design Review · Page 2", size: 34, bold: true),
            .spacer(),
            .init("SwiftData stores metadata and recognized text."),
            .init("大文件保存在沙盒目录中，数据库只保存文件名。"),
            .spacer(),
            .init("PDF pages are rendered one at a time so memory stays flat"),
            .init("even for a document with several hundred pages."),
            .spacer(),
            .init("Vision runs on a background queue; the main thread only"),
            .init("updates progress and saves small model changes.")
        ],
        [
            .init("Open Questions", size: 52, bold: true),
            .init("Design Review · Page 3", size: 34, bold: true),
            .spacer(),
            .init("How should reading order handle two column pages?"),
            .init("双栏页面先读左栏，再读右栏。"),
            .spacer(),
            .init("Should manual edits survive a second OCR pass?"),
            .init("Yes — always confirm before overwriting edited text."),
            .spacer(),
            .init("Next review: Thursday, 10:00.")
        ]
    ]
}

/// Creates the sample library shown by "Load Demo Notes".
///
/// Demo pages carry their recognized text and bounding boxes directly, so the
/// whole app — library, search, readers, OCR editing — is usable in the
/// Simulator without a camera or a test PDF, and without running Vision.
@MainActor
struct DemoDataService {
    let modelContext: ModelContext
    let storage: FileStorageServicing

    init(modelContext: ModelContext, storage: FileStorageServicing = FileStorageService.shared) {
        self.modelContext = modelContext
        self.storage = storage
    }

    func libraryIsEmpty() throws -> Bool {
        try DocumentStore(modelContext: modelContext, storage: storage).documentCount() == 0
    }

    @discardableResult
    func loadDemoNotes() async throws -> [LibraryDocument] {
        let content = try await DemoLibraryContent.render()

        let documents = [
            try makeImageDocument(
                title: "线性代数 课堂笔记",
                type: .camera,
                rendered: content.lecture,
                createdAt: Date().addingTimeInterval(-86_400 * 3)
            ),
            try makeImageDocument(
                title: "OCR Textbook Page",
                type: .photo,
                rendered: content.bookPage,
                createdAt: Date().addingTimeInterval(-86_400 * 2)
            ),
            try makePDFDocument(
                pdfData: content.pdfData,
                pages: content.pdfPages,
                createdAt: Date().addingTimeInterval(-86_400)
            )
        ]

        try DocumentStore(modelContext: modelContext, storage: storage).save()
        return documents
    }

    // MARK: - Building the documents

    private func makeImageDocument(
        title: String,
        type: DocumentType,
        rendered: DemoContentRenderer.RenderedDemoPage,
        createdAt: Date
    ) throws -> LibraryDocument {
        let documentID = UUID()
        let fileName = FileNameGenerator.sourceFileName(documentID: documentID, type: type)
        try storage.write(rendered.imageData, fileName: fileName, in: .sources)

        let document = LibraryDocument(
            id: documentID,
            title: title,
            documentType: type,
            localFileName: fileName,
            originalFileName: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            pageCount: 1,
            processingStatus: .completed,
            processingProgress: 1,
            thumbnailData: rendered.thumbnailData
        )
        modelContext.insert(document)

        let page = DocumentPage(
            pageNumber: 1,
            recognizedText: rendered.text,
            imageFileName: fileName,
            createdAt: createdAt
        )
        modelContext.insert(page)
        document.pages.append(page)
        page.textBlocks = rendered.blocks.map { TextBlock(recognized: $0) }

        return document
    }

    private func makePDFDocument(
        pdfData: Data,
        pages: [DemoContentRenderer.RenderedDemoPage],
        createdAt: Date
    ) throws -> LibraryDocument {
        let documentID = UUID()
        let fileName = FileNameGenerator.sourceFileName(documentID: documentID, type: .pdf)
        try storage.write(pdfData, fileName: fileName, in: .sources)

        let document = LibraryDocument(
            id: documentID,
            title: "Design Review Notes",
            documentType: .pdf,
            localFileName: fileName,
            originalFileName: "Design Review Notes.pdf",
            createdAt: createdAt,
            updatedAt: createdAt,
            pageCount: pages.count,
            processingStatus: .completed,
            processingProgress: 1,
            thumbnailData: pages.first?.thumbnailData
        )
        modelContext.insert(document)

        for (index, rendered) in pages.enumerated() {
            let pageNumber = PDFPageMapper.pageNumber(forIndex: index)
            let cacheFileName = FileNameGenerator.pageImageFileName(
                documentID: documentID,
                pageNumber: pageNumber
            )
            try storage.write(rendered.imageData, fileName: cacheFileName, in: .pages)

            let page = DocumentPage(
                pageNumber: pageNumber,
                recognizedText: rendered.text,
                imageFileName: cacheFileName,
                createdAt: createdAt
            )
            modelContext.insert(page)
            document.pages.append(page)
            page.textBlocks = rendered.blocks.map { TextBlock(recognized: $0) }
        }

        return document
    }
}
