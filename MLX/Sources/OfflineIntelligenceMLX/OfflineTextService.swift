import OfflineIntelligence

/// App-wide ordinary text requests. Specialist engines must release their external MLX lease first.
public enum OfflineTextService {
    public static let shared = TextGenerationSession(runtime: MLXIntelligenceRuntime.shared)
}
