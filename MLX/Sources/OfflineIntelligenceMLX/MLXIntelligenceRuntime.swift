import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import OfflineIntelligence

/// A single resident model and one compute operation at a time. Share one instance across app features.
/// The complete tensor lifecycle remains inside ModelContainer.perform's serial executor.
public actor MLXIntelligenceRuntime: IntelligenceRuntime {
    public static let shared = MLXIntelligenceRuntime()
    private let identity = UUID()
    private let cacheLimitBytes: Int
    private var container: ModelContainer?
    private var resident: ModelDescriptor?
    private var state: RuntimeState = .unloaded
    private var operationID: UUID?
    private var signal: CancellationSignal?
    private var loadTask: Task<LoadedModel, Error>?
    private var generationTask: Task<Void, Never>?
    private var unloading = false
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    public init(cacheLimitBytes: Int = 16 * 1024 * 1024) {
        self.cacheLimitBytes = max(0, cacheLimitBytes)
    }
    deinit { MLXLease.shared.release(identity) }

    public func load(model: ModelDescriptor, directory: URL) async throws -> ModelLoadMetrics {
        try Task.checkCancellation()
        guard !unloading, operationID == nil else { throw IntelligenceError.busy }
        try await MLXForegroundExecution.prepare()
        // The main-actor preflight suspends this actor, so recheck all admission state afterwards.
        guard !unloading, operationID == nil else { throw IntelligenceError.busy }
        try Task.checkCancellation()
        guard MLXForegroundExecution.isAllowed else { throw CancellationError() }
        try validateDirectory(directory, model: model)
        guard MLXLease.shared.acquire(identity) else { throw IntelligenceError.busy }
        // A switch drops the old weights before allocating the next checkpoint.
        container = nil; resident = nil
        MemoryProbe.synchronize(); Memory.clearCache()
        if let available = MemoryProbe.available {
            let required = Int(Double(model.estimatedWeightBytes) * 1.2) + 256 * 1024 * 1024
            guard available >= required else {
                state = .unloaded; MLXLease.shared.release(identity)
                throw IntelligenceError.insufficientMemory(requiredBytes: required, availableBytes: available)
            }
        }
        state = .loading
        let id = UUID(), cancellation = CancellationSignal()
        operationID = id; signal = cancellation
        let cacheLimit = cacheLimitBytes
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard MLXForegroundExecution.isAllowed else { throw CancellationError() }
            #if targetEnvironment(simulator)
            Device.setDefault(device: .cpu)
            #endif
            Memory.cacheLimit = cacheLimit
            let before = MemoryProbe.footprint, start = MemoryProbe.now
            guard MLXForegroundExecution.isAllowed else { throw CancellationError() }
            let loaded = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
            MemoryProbe.synchronize()
            guard !cancellation.isCancelled, MLXForegroundExecution.isAllowed else { throw CancellationError() }
            try Task.checkCancellation()
            let metrics = ModelLoadMetrics(modelID: model.id, durationSeconds: MemoryProbe.elapsed(since: start),
                                           footprintBeforeBytes: before, footprintAfterBytes: MemoryProbe.footprint,
                                           mlxActiveBytes: Memory.activeMemory)
            return LoadedModel(container: loaded, metrics: metrics)
        }
        loadTask = task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                cancellation.cancel()
                task.cancel()
            }
            guard operationID == id, !cancellation.isCancelled, !Task.isCancelled,
                  MLXForegroundExecution.isAllowed else { throw CancellationError() }
            container = loaded.container; resident = model; state = .ready
            operationID = nil; signal = nil; loadTask = nil
            resumeLoadWaiters()
            return loaded.metrics
        } catch {
            if operationID == id {
                operationID = nil; signal = nil; loadTask = nil
                container = nil; resident = nil; state = .unloaded
                MemoryProbe.synchronize(); Memory.clearCache(); MLXLease.shared.release(identity)
                resumeLoadWaiters()
            }
            throw error
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        try Task.checkCancellation()
        try request.validate()
        guard !unloading, operationID == nil else { throw IntelligenceError.busy }
        try await MLXForegroundExecution.prepare()
        guard !unloading, operationID == nil else { throw IntelligenceError.busy }
        try Task.checkCancellation()
        guard MLXForegroundExecution.isAllowed else { throw CancellationError() }
        guard let container, let model = resident else { throw IntelligenceError.modelNotLoaded }
        let id = UUID(), cancellation = CancellationSignal()
        operationID = id; signal = cancellation; state = .generating
        let pair = AsyncThrowingStream<GenerationEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        pair.continuation.onTermination = { termination in
            if case .cancelled = termination { cancellation.cancel() }
        }
        generationTask = Task.detached(priority: .userInitiated) { [self] in
            do {
                let metrics = try await container.perform { context in
                    try TextGeneration.run(context: context, model: model, request: request,
                                           cancellation: cancellation, continuation: pair.continuation)
                }
                // The worker is finished before admission reopens. While inactive, the gate refuses new work
                // and avoids a GPU barrier that would itself submit a forbidden background command buffer.
                cancellation.clearHandler()
                await generationEnded(id)
                pair.continuation.yield(.completed(metrics))
                pair.continuation.finish()
            } catch {
                MemoryProbe.synchronize()
                cancellation.clearHandler()
                await generationEnded(id)
                pair.continuation.finish(throwing: error)
            }
        }
        if let task = generationTask { cancellation.register { task.cancel() } }
        return pair.stream
    }

    public func cancel() async {
        guard let id = operationID else { return }
        state = .cancelling
        signal?.cancel()
        if let task = generationTask {
            task.cancel()
            await task.value
        } else if let task = loadTask {
            task.cancel()
            _ = try? await task.value
            // The owner load() frame must also release its LoadedModel/task result before admission reopens.
            if operationID == id { await withCheckedContinuation { loadWaiters.append($0) } }
        }
    }

    public func unload() async {
        if unloading {
            await withCheckedContinuation { unloadWaiters.append($0) }
            return
        }
        unloading = true
        await cancel()
        container = nil; resident = nil
        MemoryProbe.synchronize(); Memory.clearCache()
        MLXLease.shared.release(identity)
        state = .unloaded; unloading = false
        let waiters = unloadWaiters; unloadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    public func snapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(state: state, model: resident, footprintBytes: MemoryProbe.footprint,
                        mlxActiveBytes: Memory.activeMemory, mlxCacheBytes: Memory.cacheMemory)
    }

    private func resumeLoadWaiters() {
        let waiters = loadWaiters; loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func generationEnded(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil; signal = nil; generationTask = nil
        state = resident == nil ? .unloaded : .ready
    }

    private func validateDirectory(_ directory: URL, model: ModelDescriptor) throws {
        guard directory.isFileURL else { throw IntelligenceError.invalidModelDirectory("only local file URLs are accepted") }
        guard ModelCatalog.all.contains(model) else { throw IntelligenceError.invalidModelDirectory("checkpoint is not in the pinned model catalog") }
        let manager = FileManager.default
        for filename in ["config.json", "tokenizer.json", "tokenizer_config.json", "model-metadata.json"] {
            guard manager.fileExists(atPath: directory.appendingPathComponent(filename).path) else {
                throw IntelligenceError.invalidModelDirectory("missing \(filename)")
            }
        }
        let metadataData = try Data(contentsOf: directory.appendingPathComponent("model-metadata.json"))
        guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              metadata["schemaVersion"] as? Int == 1,
              metadata["repositoryID"] as? String == model.repositoryID,
              metadata["revision"] as? String == model.revision,
              metadata["quantizationBits"] as? Int == model.quantizationBits else {
            throw IntelligenceError.invalidModelDirectory("model metadata does not match the pinned checkpoint repository, revision, and quantization")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["model_type"] as? String == "qwen3_5",
              let quantization = (config["quantization"] ?? config["quantization_config"]) as? [String: Any],
              quantization["bits"] as? Int == 4 else {
            throw IntelligenceError.invalidModelDirectory("expected qwen3_5 configuration with 4-bit quantization")
        }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        guard files.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw IntelligenceError.invalidModelDirectory("missing safetensors weights")
        }
    }
}

private struct LoadedModel: Sendable {
    let container: ModelContainer
    let metrics: ModelLoadMetrics
}
