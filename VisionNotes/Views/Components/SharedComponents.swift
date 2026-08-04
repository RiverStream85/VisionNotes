import SwiftUI

/// A user-presentable error, ready for `.alert(item:)`.
struct ErrorAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(_ error: Error) {
        let appError = AppError.wrap(error) { AppError.persistenceSaveFailed(reason: $0) }
        title = appError.errorDescription ?? "Something went wrong"
        message = appError.recoverySuggestion ?? ""
    }
}

extension View {
    func errorAlert(_ error: Binding<ErrorAlert?>) -> some View {
        alert(item: error) { alert in
            Alert(
                title: Text(alert.title),
                message: alert.message.isEmpty ? nil : Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

/// Source-type chip used in library rows and search results.
struct SourceTypeBadge: View {
    let type: DocumentType

    var body: some View {
        Label(type.displayName, systemImage: type.systemImageName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Source: \(type.displayName)")
    }
}

/// OCR status chip, with a progress bar while a document is processing.
struct ProcessingStatusView: View {
    let status: ProcessingStatus
    let progress: Double

    var body: some View {
        switch status {
        case .processing:
            HStack(spacing: 6) {
                ProgressView(value: max(min(progress, 1), 0))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 90)
                Text("\(Int((max(min(progress, 1), 0)) * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Recognizing text, \(Int(progress * 100)) percent")
        default:
            Label(status.displayName, systemImage: status.systemImageName)
                .font(.caption2)
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .pending: return .secondary
        case .processing: return .accentColor
        }
    }
}

/// Thumbnail with a placeholder for documents that have none yet.
struct DocumentThumbnail: View {
    let data: Data?
    let type: DocumentType
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: type.systemImageName)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size * 1.28)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .accessibilityHidden(true)
    }
}

/// Text with the search terms highlighted.
struct HighlightedText: View {
    let snippet: TextSnippet
    var font: Font = .subheadline

    var body: some View {
        Text(attributed)
            .font(font)
            .lineLimit(3)
    }

    private var attributed: AttributedString {
        var result = AttributedString(snippet.text)
        for range in snippet.highlightRanges {
            guard let attributedRange = Range(range, in: result) else { continue }
            result[attributedRange].backgroundColor = Color.yellow.opacity(0.45)
            result[attributedRange].font = font.weight(.semibold)
        }
        return result
    }
}

/// Highlights every occurrence of `terms` inside a longer body of text.
struct HighlightedBodyText: View {
    let text: String
    let terms: [String]
    var font: Font = .body

    var body: some View {
        Text(attributed)
            .font(font)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        guard !terms.isEmpty else { return result }
        let ranges = SearchEngine().highlightRanges(in: text, terms: terms)
        for range in ranges {
            guard let attributedRange = Range(range, in: result) else { continue }
            result[attributedRange].backgroundColor = Color.yellow.opacity(0.45)
            result[attributedRange].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}
