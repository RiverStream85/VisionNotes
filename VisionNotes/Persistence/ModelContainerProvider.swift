import Foundation
import SwiftData

/// Builds the app's SwiftData container.
///
/// If the on-disk store cannot be opened — a corrupt file, or a schema left
/// over from an older build — the app falls back to an in-memory container so
/// the first launch never crashes. The UI surfaces that as a warning.
enum ModelContainerProvider {
    static let schema = Schema([
        LibraryDocument.self,
        DocumentPage.self,
        TextBlock.self
    ])

    struct Result {
        let container: ModelContainer
        /// Non-nil when the persistent store could not be opened.
        let warning: String?
    }

    static func makeContainer(inMemory: Bool = false) -> Result {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return Result(container: container, warning: nil)
        } catch {
            let fallbackConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                let container = try ModelContainer(for: schema, configurations: [fallbackConfiguration])
                return Result(
                    container: container,
                    warning: "Your library could not be opened, so this session runs in memory only. Changes will not be saved."
                )
            } catch {
                // A container that cannot be created even in memory means the
                // schema itself is broken, which is a programmer error.
                fatalError("Unable to create a SwiftData container: \(error.localizedDescription)")
            }
        }
    }
}
