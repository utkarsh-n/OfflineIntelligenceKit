import Foundation

/// A fixed, local checkpoint. Repository information records provenance; runtime loading never fetches it.
public struct ModelDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let parameterBillions: Double
    public let quantizationBits: Int
    public let repositoryID: String
    public let revision: String
    public let contextWindowTokens: Int
    public let estimatedWeightBytes: Int

    public init(id: String, displayName: String, parameterBillions: Double, quantizationBits: Int,
                repositoryID: String, revision: String, contextWindowTokens: Int, estimatedWeightBytes: Int) {
        self.id = id; self.displayName = displayName; self.parameterBillions = parameterBillions
        self.quantizationBits = quantizationBits; self.repositoryID = repositoryID; self.revision = revision
        self.contextWindowTokens = contextWindowTokens; self.estimatedWeightBytes = estimatedWeightBytes
    }
}

public enum ModelCatalog {
    public static let qwen2B = ModelDescriptor(
        id: "qwen3.5-2b-4bit", displayName: "Qwen3.5 2B · 4-bit", parameterBillions: 2,
        quantizationBits: 4, repositoryID: "mlx-community/Qwen3.5-2B-4bit",
        revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207", contextWindowTokens: 262_144,
        estimatedWeightBytes: 1_722_271_785)
    public static let qwen4B = ModelDescriptor(
        id: "qwen3.5-4b-4bit", displayName: "Qwen3.5 4B · 4-bit", parameterBillions: 4,
        quantizationBits: 4, repositoryID: "mlx-community/Qwen3.5-4B-4bit",
        revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c", contextWindowTokens: 262_144,
        estimatedWeightBytes: 3_034_300_695)
    public static let all = [qwen2B, qwen4B]
}

public enum IntelligenceError: Error, Equatable, Sendable, LocalizedError {
    case busy
    case modelNotLoaded
    case invalidRequest(String)
    case invalidModelDirectory(String)
    case insufficientMemory(requiredBytes: Int, availableBytes: Int)
    case promptTooLong(actual: Int, limit: Int)
    case contextTooLong(actual: Int, limit: Int)
    case invalidStructuredOutput(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .busy: "The intelligence runtime is already loading, generating, or unloading."
        case .modelNotLoaded: "Load a local model before generating."
        case .invalidRequest(let reason): "Invalid generation request: \(reason)"
        case .invalidModelDirectory(let reason): "Invalid local model: \(reason)"
        case .insufficientMemory(let required, let available): "Model needs approximately \(required) bytes; this process has \(available) bytes available."
        case .promptTooLong(let actual, let limit): "Prompt contains \(actual) tokens; limit is \(limit)."
        case .contextTooLong(let actual, let limit): "Prompt plus output budget is \(actual) tokens; context limit is \(limit)."
        case .invalidStructuredOutput(let reason): "Invalid structured output: \(reason)"
        case .generationFailed(let reason): "The local model could not complete the response: \(reason)"
        }
    }
}
