import SwiftUI

struct LibraryRow: View {
    let document: LibraryDocument

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                Text(((try? document.title) ?? "Note unavailable"))
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
                    switch Result(catching: { try document.textPreview() }) {
                    case .success(let preview) where !preview.isEmpty:
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    case .success:
                        Text(document.processingStatus == .completed ? "No text recognized." : "Waiting for text recognition…")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    case .failure:
                        Label("Encrypted text unavailable", systemImage: "exclamationmark.lock")
                            .font(.subheadline)
                            .foregroundStyle(.red)
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

    @ViewBuilder
    private var thumbnail: some View {
        switch Result(catching: { try document.decryptedThumbnailData() }) {
        case .success(let data):
            DocumentThumbnail(data: data, type: document.documentType)
        case .failure:
            Image(systemName: "exclamationmark.lock")
                .frame(width: 58, height: 72)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.red)
                .accessibilityLabel("Encrypted thumbnail unavailable")
        }
    }
}
