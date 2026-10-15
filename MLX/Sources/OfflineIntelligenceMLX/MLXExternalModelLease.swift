import Foundation
import OfflineIntelligence

/// Coordinates a specialist MLX engine (e.g. embeddings or instrumented attention) with this runtime.
/// Hold the lease for the entire tensor residency. Drain GPU work and release all tensors before release().
public final class MLXExternalModelLease: Sendable {
    private let identity = UUID()
    public init() {}
    public func acquire() throws {
        guard MLXLease.shared.acquire(identity) else { throw IntelligenceError.busy }
    }
    public func release() { MLXLease.shared.release(identity) }
    deinit { MLXLease.shared.release(identity) }
}
