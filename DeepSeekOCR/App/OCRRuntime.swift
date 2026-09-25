import Foundation

private func decodeErrorBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private final class NativeOCRContext: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        dsocr_destroy(pointer)
    }
}

private final class NativeCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: NativeOCRContext?

    func install(_ context: NativeOCRContext) {
        lock.lock()
        self.context = context
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let pointer = context?.pointer
        lock.unlock()
        if let pointer {
            dsocr_cancel(pointer)
        }
    }
}

actor OCRRuntime {
    private var nativeContext: NativeOCRContext?
    nonisolated private let cancellationBox = NativeCancellationBox()

    func recognize(
        imageData: Data,
        prompt: String,
        performanceMode: OCRPerformanceMode,
        maxTokens: Int = 3072
    ) throws -> OCRResult {
        try Task.checkCancellation()
        if nativeContext == nil {
            let paths = try ModelLocator.bundledModels()
            var error = [CChar](repeating: 0, count: 8192)
            let created = paths.text.path.withCString { modelPath in
                paths.vision.path.withCString { visionPath in
                    dsocr_create(modelPath, visionPath, 4096, 4, &error, error.count)
                }
            }
            guard let created else {
                throw OCRError.loadFailed(decodeErrorBuffer(error))
            }
            let context = NativeOCRContext(created)
            nativeContext = context
            cancellationBox.install(context)
        }

        try Task.checkCancellation()

        guard let context = nativeContext?.pointer else {
            throw OCRError.loadFailed("DeepSeek OCR did not initialize.")
        }
        dsocr_reset_cancel(context)
        try Task.checkCancellation()

        var output: UnsafeMutablePointer<CChar>?
        var nativeMetrics = DSOCRMetrics()
        var error = [CChar](repeating: 0, count: 8192)

        let status = imageData.withUnsafeBytes { bytes in
            prompt.withCString { promptPointer in
                dsocr_recognize_with_vision_mode(
                    context,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    promptPointer,
                    Int32(maxTokens),
                    performanceMode.nativeValue,
                    &output,
                    &nativeMetrics,
                    &error,
                    error.count
                )
            }
        }

        if status == 8 {
            throw CancellationError()
        }
        guard status == 0, let output else {
            throw OCRError.inferenceFailed(decodeErrorBuffer(error))
        }
        defer { dsocr_string_free(output) }
        try Task.checkCancellation()

        return OCRResult(
            text: String(
                decodingCString: UnsafeRawPointer(output).assumingMemoryBound(to: UInt8.self),
                as: UTF8.self
            ),
            metrics: OCRMetrics(
                modelLoadSeconds: nativeMetrics.model_load_seconds,
                encodeSeconds: nativeMetrics.encode_seconds,
                generationSeconds: nativeMetrics.generation_seconds,
                inputTokens: Int(nativeMetrics.input_tokens),
                outputTokens: Int(nativeMetrics.output_tokens),
                isTruncated: nativeMetrics.output_truncated,
                fastVisionUsed: nativeMetrics.fast_vision_used
            )
        )
    }

    nonisolated func cancel() {
        cancellationBox.cancel()
    }
}
