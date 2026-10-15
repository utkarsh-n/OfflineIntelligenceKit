import Foundation

public enum StructuredOutput {
    /// Decodes the complete JSON response then applies application-owned semantic validation.
    /// This is validation after generation, not constrained decoding: callers must reject invalid or truncated results.
    public static func decode<T: Decodable>(_ text: String, as type: T.Type,
                                           validate: (T) throws -> Void = { _ in }) throws -> T {
        guard text.utf8.count <= 128 * 1024 else { throw IntelligenceError.invalidStructuredOutput("response exceeds 128 KiB") }
        do {
            let value = try JSONDecoder().decode(type, from: Data(text.utf8))
            try validate(value)
            return value
        } catch {
            throw IntelligenceError.invalidStructuredOutput(String(describing: error))
        }
    }
}
