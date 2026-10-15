import Foundation

public struct GenerationRequest: Codable, Equatable, Sendable {
    public static let defaultSystem = "You are a concise, accurate assistant. Follow the requested output format."
    public let system: String
    public let prompt: String
    public let maxOutputTokens: Int
    public let maxPromptTokens: Int
    public let maxContextTokens: Int
    public let temperature: Float
    public let topP: Float
    public let seed: UInt64
    public let timeoutSeconds: Double

    public init(system: String = Self.defaultSystem, prompt: String, maxOutputTokens: Int = 256,
                maxPromptTokens: Int = 2048, maxContextTokens: Int = 4096,
                temperature: Float = 0, topP: Float = 1, seed: UInt64 = 42, timeoutSeconds: Double = 120) {
        self.system = system; self.prompt = prompt; self.maxOutputTokens = maxOutputTokens
        self.maxPromptTokens = maxPromptTokens; self.maxContextTokens = maxContextTokens
        self.temperature = temperature; self.topP = topP; self.seed = seed; self.timeoutSeconds = timeoutSeconds
    }

    /// Conservative mobile budgets are enforced before tokenization and again on the rendered chat tokens.
    public func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceError.invalidRequest("prompt is empty")
        }
        guard prompt.utf8.count + system.utf8.count <= 128 * 1024 else {
            throw IntelligenceError.invalidRequest("prompt text exceeds 128 KiB")
        }
        guard (1...1024).contains(maxOutputTokens) else { throw IntelligenceError.invalidRequest("output cap must be 1...1024 tokens") }
        guard (1...8192).contains(maxPromptTokens) else { throw IntelligenceError.invalidRequest("prompt cap must be 1...8192 tokens") }
        guard (2...16384).contains(maxContextTokens), maxOutputTokens < maxContextTokens else {
            throw IntelligenceError.invalidRequest("context cap must be 2...16384 tokens and exceed output cap")
        }
        guard temperature.isFinite, (0...2).contains(temperature) else { throw IntelligenceError.invalidRequest("temperature must be finite and in 0...2") }
        guard topP.isFinite, (0...1).contains(topP), topP > 0 else { throw IntelligenceError.invalidRequest("topP must be finite and in (0,1]") }
        guard timeoutSeconds.isFinite, (1...600).contains(timeoutSeconds) else { throw IntelligenceError.invalidRequest("timeout must be finite and in 1...600 seconds") }
    }

    public func validateTokenCount(_ count: Int, model: ModelDescriptor) throws {
        try validate()
        guard count > 0 else { throw IntelligenceError.invalidRequest("tokenized prompt is empty") }
        guard count <= maxPromptTokens else { throw IntelligenceError.promptTooLong(actual: count, limit: maxPromptTokens) }
        let limit = min(maxContextTokens, model.contextWindowTokens)
        guard count + maxOutputTokens <= limit else {
            throw IntelligenceError.contextTooLong(actual: count + maxOutputTokens, limit: limit)
        }
    }
}

public enum GenerationFinishReason: String, Codable, Equatable, Sendable { case stop, length, cancelled, timeout }

/// All durations use a monotonic clock. First token timing includes chat rendering/tokenization and prefill.
/// Footprint is sampled process memory, while MLX allocation is separately measured GPU allocator memory.
public struct GenerationMetrics: Codable, Equatable, Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let firstTokenSeconds: Double?
    public let generationSeconds: Double
    public let decodeSeconds: Double
    public let peakFootprintBytes: Int?
    public let mlxPeakAllocatedBytes: Int
    public let finishReason: GenerationFinishReason

    public init(promptTokens: Int, generatedTokens: Int, firstTokenSeconds: Double?, generationSeconds: Double,
                decodeSeconds: Double, peakFootprintBytes: Int?, mlxPeakAllocatedBytes: Int,
                finishReason: GenerationFinishReason) {
        self.promptTokens = promptTokens; self.generatedTokens = generatedTokens; self.firstTokenSeconds = firstTokenSeconds
        self.generationSeconds = generationSeconds; self.decodeSeconds = decodeSeconds
        self.peakFootprintBytes = peakFootprintBytes; self.mlxPeakAllocatedBytes = mlxPeakAllocatedBytes; self.finishReason = finishReason
    }

    /// Excludes the first generated token, whose latency is included in firstTokenSeconds.
    public var tokensPerSecond: Double { decodeSeconds > 0 ? Double(max(0, generatedTokens - 1)) / decodeSeconds : 0 }
}

public enum GenerationEvent: Sendable, Equatable {
    case chunk(String)
    case completed(GenerationMetrics)
}

public struct ModelLoadMetrics: Codable, Equatable, Sendable {
    public let modelID: String
    public let durationSeconds: Double
    public let footprintBeforeBytes: Int?
    public let footprintAfterBytes: Int?
    public let mlxActiveBytes: Int
    public init(modelID: String, durationSeconds: Double, footprintBeforeBytes: Int?, footprintAfterBytes: Int?, mlxActiveBytes: Int) {
        self.modelID = modelID; self.durationSeconds = durationSeconds; self.footprintBeforeBytes = footprintBeforeBytes
        self.footprintAfterBytes = footprintAfterBytes; self.mlxActiveBytes = mlxActiveBytes
    }
}

public enum RuntimeState: String, Codable, Sendable { case unloaded, loading, ready, generating, cancelling }

public struct RuntimeSnapshot: Codable, Equatable, Sendable {
    public let state: RuntimeState
    public let model: ModelDescriptor?
    public let footprintBytes: Int?
    public let mlxActiveBytes: Int
    public let mlxCacheBytes: Int
    public init(state: RuntimeState, model: ModelDescriptor?, footprintBytes: Int?, mlxActiveBytes: Int, mlxCacheBytes: Int) {
        self.state = state; self.model = model; self.footprintBytes = footprintBytes
        self.mlxActiveBytes = mlxActiveBytes; self.mlxCacheBytes = mlxCacheBytes
    }
}

public protocol IntelligenceRuntime: Sendable {
    func load(model: ModelDescriptor, directory: URL) async throws -> ModelLoadMetrics
    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error>
    /// Returns only after the actual compute worker exits. Cancellation is cooperative between prefill/decode steps.
    func cancel() async
    /// Cancels and drains work, releases weights, synchronizes GPU work, and clears MLX's reusable buffer cache.
    func unload() async
    func snapshot() async -> RuntimeSnapshot
}
