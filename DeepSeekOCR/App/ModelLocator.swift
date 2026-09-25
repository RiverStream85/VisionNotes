import Foundation

struct ModelPaths: Sendable {
    let text: URL
    let vision: URL
}

enum ModelLocator {
    private static let textName = "deepseek-ocr-2-Q4_K_M"
    private static let visionName = "mmproj-deepseek-ocr-2-q8_0"

    static func bundledModels() throws -> ModelPaths {
        guard let text = find(textName), let vision = find(visionName) else {
            throw OCRError.missingModels
        }
        return ModelPaths(text: text, vision: vision)
    }

    private static func find(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "gguf", subdirectory: "ModelAssets")
            ?? Bundle.main.url(forResource: name, withExtension: "gguf")
    }
}

