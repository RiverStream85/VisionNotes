import SwiftUI

struct LibraryRow: View {
    let document: LibraryDocument

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DocumentThumbnail(data: document.thumbnailData, type: document.documentType)

            VStack(alignment: .leading, spacing: 6) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    SourceTypeBadge(type: document.documentType)
                    Text(pageCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(document.createdAt, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProcessingStatusView(
                    status: document.processingStatus,
                    progress: document.processingProgress
                )

                if document.processingStatus == .failed, let error = document.processingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    let preview = document.textPreview()
                    if preview.isEmpty {
                        Text(document.processingStatus == .completed ? "No text recognized." : "Waiting for text recognition…")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var pageCountText: String {
        document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"
    }
}
