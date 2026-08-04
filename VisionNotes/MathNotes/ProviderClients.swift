import Foundation

struct PreparedProviderRequest: Sendable {
    let request: URLRequest
    let body: Data
}

enum ProviderRequestBuilder {
    static let mistralEndpoint = URL(string: "https://api.mistral.ai/v1/ocr")!
    static let siliconFlowEndpoint = URL(string: "https://api.siliconflow.cn/v1/chat/completions")!

    static func mistralOCR(data: Data, mimeType: String, key: String) throws -> PreparedProviderRequest {
        let isPDF = mimeType == "application/pdf"
        let document: [String: Any] = isPDF
            ? ["type": "document_url", "document_url": "data:\(mimeType);base64,\(data.base64EncodedString())"]
            : ["type": "image_url", "image_url": "data:\(mimeType);base64,\(data.base64EncodedString())"]
        let payload: [String: Any] = [
            "model": MistralOCRClient.model,
            "document": document,
            "table_format": "markdown",
            "include_blocks": true,
            "include_image_base64": true
        ]
        return try makeRequest(url: mistralEndpoint, key: key, payload: payload)
    }

    static func siliconFlowVision(
        imageData: Data,
        mimeType: String,
        prompt: String,
        key: String,
        maxTokens: Int = 5_000
    ) throws -> PreparedProviderRequest {
        let content: [[String: Any]] = [
            ["type": "text", "text": prompt],
            [
                "type": "image_url",
                "image_url": [
                    "url": "data:\(mimeType);base64,\(imageData.base64EncodedString())",
                    "detail": "high"
                ]
            ]
        ]
        let payload: [String: Any] = [
            "model": SiliconFlowVisionClient.model,
            "messages": [["role": "user", "content": content]],
            "temperature": 0,
            "max_tokens": maxTokens
        ]
        return try makeRequest(url: siliconFlowEndpoint, key: key, payload: payload)
    }

    static func siliconFlowMerge(prompt: String, key: String) throws -> PreparedProviderRequest {
        let payload: [String: Any] = [
            "model": SiliconFlowVisionClient.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0,
            "max_tokens": 7_000
        ]
        return try makeRequest(url: siliconFlowEndpoint, key: key, payload: payload)
    }

    private static func makeRequest(
        url: URL,
        key: String,
        payload: [String: Any]
    ) throws -> PreparedProviderRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return PreparedProviderRequest(request: request, body: body)
    }
}

final class RetryingProviderHTTPClient: @unchecked Sendable {
    static let retryableStatusCodes: Set<Int> = [408, 409, 425, 429, 500, 502, 503, 504]

    private let session: URLSession
    private let maximumRetries: Int

    init(session: URLSession? = nil, maximumRetries: Int = 3) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 180
            configuration.waitsForConnectivity = true
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
        self.maximumRetries = maximumRetries
    }

    func upload(_ prepared: PreparedProviderRequest) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.upload(for: prepared.request, from: prepared.body)
                guard let http = response as? HTTPURLResponse else {
                    throw MathNoteError.providerUnavailable
                }
                guard (200..<300).contains(http.statusCode) else {
                    if Self.retryableStatusCodes.contains(http.statusCode), attempt < maximumRetries {
                        let delay = retryDelay(attempt: attempt, response: http)
                        attempt += 1
                        try await sleep(seconds: delay)
                        continue
                    }
                    throw MathNoteError.providerRejected(status: http.statusCode)
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MathNoteError {
                throw error
            } catch {
                guard attempt < maximumRetries else { throw MathNoteError.providerUnavailable }
                let delay = min(pow(2, Double(attempt)), 30)
                attempt += 1
                try await sleep(seconds: delay)
            }
        }
    }

    private func retryDelay(attempt: Int, response: HTTPURLResponse) -> TimeInterval {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(value) {
            return min(max(seconds, 0), 30)
        }
        return min(pow(2, Double(attempt)), 30)
    }

    private func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

struct MistralOCRClient: Sendable {
    static let model = "mistral-ocr-latest"

    private let key: String
    private let httpClient: RetryingProviderHTTPClient

    init(key: String, httpClient: RetryingProviderHTTPClient = RetryingProviderHTTPClient()) {
        self.key = key
        self.httpClient = httpClient
    }

    func recognize(documentData: Data, mimeType: String) async throws -> Data {
        let request = try ProviderRequestBuilder.mistralOCR(
            data: documentData,
            mimeType: mimeType,
            key: key
        )
        return try await httpClient.upload(request)
    }
}

struct SiliconFlowCompletion: Codable, Equatable, Sendable {
    let text: String
    let usage: ProviderTokenUsage?
}

struct SiliconFlowVisionClient: Sendable {
    static let model = "Qwen/Qwen3-VL-32B-Instruct"

    private let key: String
    private let httpClient: RetryingProviderHTTPClient

    init(
        key: String,
        httpClient: RetryingProviderHTTPClient = RetryingProviderHTTPClient(maximumRetries: 0)
    ) {
        self.key = key
        self.httpClient = httpClient
    }

    func transcribe(
        imageData: Data,
        mimeType: String,
        prompt: String,
        maxTokens: Int = 5_000
    ) async throws -> SiliconFlowCompletion {
        let request = try ProviderRequestBuilder.siliconFlowVision(
            imageData: imageData,
            mimeType: mimeType,
            prompt: prompt,
            key: key,
            maxTokens: maxTokens
        )
        return try decodeCompletion(try await httpClient.upload(request))
    }

    func merge(prompt: String) async throws -> SiliconFlowCompletion {
        let request = try ProviderRequestBuilder.siliconFlowMerge(prompt: prompt, key: key)
        return try decodeCompletion(try await httpClient.upload(request))
    }

    private func decodeCompletion(_ data: Data) throws -> SiliconFlowCompletion {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = response.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MathNoteError.malformedProviderResponse
        }
        let usage = response.usage.map {
            ProviderTokenUsage(
                promptTokens: $0.promptTokens,
                completionTokens: $0.completionTokens,
                totalTokens: $0.totalTokens
            )
        }
        return SiliconFlowCompletion(text: text, usage: usage)
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
    let choices: [Choice]
    let usage: Usage?
}

struct MistralAsset: Equatable, Sendable {
    let originalName: String
    let localName: String
    let data: Data
}

struct MistralParsedDocument: Equatable, Sendable {
    let pages: [String]
    let assets: [MistralAsset]
}

enum MistralOCRParser {
    static func parse(_ data: Data) throws -> MistralParsedDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPages = root["pages"] as? [[String: Any]] else {
            throw MathNoteError.malformedProviderResponse
        }

        var allAssets: [MistralAsset] = []
        var usedNames: Set<String> = []
        var pageMarkdown: [String] = []

        for (pageIndex, page) in rawPages.enumerated() {
            var markdown = page["markdown"] as? String ?? ""
            let rawImages = page["images"] as? [[String: Any]] ?? []
            var pageAssets: [MistralAsset] = []

            for (imageIndex, image) in rawImages.enumerated() {
                guard let encoded = (image["image_base64"] ?? image["base64"]) as? String,
                      let imageData = decodeDataURI(encoded) else { continue }
                let original = (image["id"] ?? image["name"] ?? image["image_id"]) as? String
                    ?? "figure-\(imageIndex + 1)"
                let ext = imageExtension(for: encoded)
                let stem = sanitize(original).replacingOccurrences(of: ".\(ext)", with: "")
                let proposed = String(format: "page-%03d-%@.%@", pageIndex + 1, stem, ext)
                let localName = uniqueName(proposed, used: &usedNames)
                let asset = MistralAsset(originalName: original, localName: localName, data: imageData)
                pageAssets.append(asset)
                allAssets.append(asset)
            }

            for asset in pageAssets {
                markdown = markdown.replacingOccurrences(of: asset.originalName, with: "assets/\(asset.localName)")
                if !markdown.contains("assets/\(asset.localName)") {
                    markdown += "\n\n![Extracted figure](assets/\(asset.localName))"
                }
            }
            pageMarkdown.append(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return MistralParsedDocument(pages: pageMarkdown, assets: allAssets)
    }

    private static func decodeDataURI(_ value: String) -> Data? {
        let payload = value.split(separator: ",", maxSplits: 1).last.map(String.init) ?? value
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }

    private static func imageExtension(for value: String) -> String {
        if value.hasPrefix("data:image/jpeg") || value.hasPrefix("data:image/jpg") { return "jpg" }
        if value.hasPrefix("data:image/gif") { return "gif" }
        if value.hasPrefix("data:image/webp") { return "webp" }
        return "png"
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let collapsed = String(value).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return String(collapsed.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .nonEmpty ?? "figure"
    }

    private static func uniqueName(_ proposed: String, used: inout Set<String>) -> String {
        if used.insert(proposed).inserted { return proposed }
        let url = URL(fileURLWithPath: proposed)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = "\(stem)-\(counter).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            counter += 1
        }
    }
}

enum MathNotePrompts {
    static let overview = """
    You are a meticulous mathematical manuscript transcriber.
    Transcribe this complete document page into human-readable Markdown with LaTeX math.

    Rules:
    - Transcribe only deliberate foreground writing or printing. Ignore faint mirrored show-through, paper ruling, empty form labels, shadows, and neighboring pages.
    - Preserve the visible hierarchy, reading order, definitions, propositions, numbered statements, bullets, tables, captions, and meaningful annotations.
    - Preserve every mathematical distinction exactly: bars, calligraphic/fraktur letters, subscripts, superscripts, inequality signs, unions, infinity, arrows, and parentheses.
    - Never normalize letter styles: $\\bar K$, $\\mathbb K$, and plain $K$ are distinct.
    - Use standard LaTeX commands in $...$ or $$...$$.
    - Do not repair the author's mathematics and do not add explanations.
    - If a symbol is genuinely unreadable, write [unclear: ...] instead of guessing.
    - Return only Markdown, without a code fence or commentary.
    """

    static let crop = """
    You are a meticulous mathematical manuscript transcriber.
    This is one high-resolution crop from a larger document page. Transcribe every deliberate foreground mark visible in this crop into Markdown with LaTeX math, in reading order.

    Rules:
    - Do not infer or repeat material outside the crop.
    - Ignore faint mirrored show-through, paper ruling, shadows, and neighboring pages.
    - Preserve exact mathematical symbols, bars, letter styles, subscripts, superscripts, arrows, inequalities, annotations, and wording. Do not silently correct the author.
    - Inspect overlines closely: $\\bar K$, $\\mathbb K$, and plain $K$ are distinct.
    - If a symbol is genuinely unreadable, write [unclear: ...] instead of guessing.
    - Return only Markdown, without a code fence or commentary.
    """

    static func merge(overview: String, crops: [String], legacy: String) -> String {
        let labeled = crops.enumerated().map { offset, transcript in
            "### Crop \(offset + 1)/\(crops.count), top to bottom\n\(transcript)"
        }.joined(separator: "\n\n")
        return """
        You are the final editor of a mathematical document transcription.
        Reconstruct one clean Markdown page from the evidence below.

        Evidence priority:
        1. Complete-page overview is the canonical inventory of lines and statements.
        2. High-resolution crops correct characters and math symbols on matching overview lines.
        3. Legacy OCR only for omissions and Markdown image links; it is error-prone.

        Requirements:
        - Include content only when supported by the supplied evidence. Do not add explanations, repair mathematics, or turn implications into stronger claims.
        - Do not add a statement that appears only in one crop. A crop may correct a matching overview line, but it must not expand the overview with a new formula or claim.
        - Resolve overlap between crops without duplicating content.
        - Overlapping crops often give two different readings of the same line. Emit that line only once, choosing the reading best supported by the overview and the clearest crop.
        - Preserve headings, definitions, propositions, lists, tables, captions, and annotations.
        - Never normalize letter styles. In particular, retain crop evidence distinguishing $\\bar K$, $\\mathbb K$, and plain $K$.
        - Preserve every Markdown image reference from the legacy OCR exactly once and place it near its original context.
        - Ignore empty printed form labels such as `No.` and `Date.` even if legacy OCR includes them.
        - Use Markdown headings, bold labels, paragraphs, and lists for prose; use LaTeX math mode only for symbols and formulas.
        - Return only the final Markdown page, with no code fence or commentary.

        ## Complete-page overview
        \(overview)

        ## High-resolution crops
        \(labeled)

        ## Legacy OCR draft
        \(legacy)
        """
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
