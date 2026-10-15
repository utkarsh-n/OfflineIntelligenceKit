import Foundation

public struct GenerationResponse: Sendable {
    public let text: String
    public let model: ModelDescriptor
    public let metrics: GenerationMetrics
    public let loadMetrics: ModelLoadMetrics?
}

/// A bounded request transaction for hosts that need a complete response, rather than their own stream loop.
/// Partial, timed-out and cancelled responses never become successful domain results.
public actor TextGenerationSession {
    private let runtime: any IntelligenceRuntime
    private var operationID: UUID?
    private var cancellationRequested = false
    private var cancellationTask: Task<Void, Never>?
    private var unloading = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []

    public init(runtime: any IntelligenceRuntime) { self.runtime = runtime }

    public func respond(to request: GenerationRequest, model: ModelDescriptor, directory: URL,
                        releaseModelAfterResponse: Bool = true,
                        onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> GenerationResponse {
        try Task.checkCancellation()
        try request.validate()
        guard operationID == nil, !unloading else { throw IntelligenceError.busy }
        let id = UUID()
        operationID = id
        cancellationRequested = false
        do {
            let response = try await withTaskCancellationHandler {
                let snapshot = await runtime.snapshot()
                try check(operation: id)
                let load: ModelLoadMetrics?
                if snapshot.model == model && snapshot.state == .ready { load = nil }
                else { load = try await runtime.load(model: model, directory: directory) }
                try check(operation: id)
                let events = try await runtime.generate(request)
                try check(operation: id)
                var text = ""
                var byteCount = 0
                var completion: GenerationMetrics?
                for try await event in events {
                    try check(operation: id)
                    switch event {
                    case .chunk(let chunk):
                        guard completion == nil else { throw IntelligenceError.generationFailed("text arrived after completion") }
                        byteCount += chunk.utf8.count
                        guard byteCount <= 128 * 1024 else { throw IntelligenceError.generationFailed("the response exceeded 128 KiB") }
                        text += chunk
                        onText(chunk)
                    case .completed(let metrics):
                        guard completion == nil else { throw IntelligenceError.generationFailed("the stream contained duplicate completions") }
                        completion = metrics
                    }
                }
                try check(operation: id)
                guard let completion else { throw IntelligenceError.generationFailed("the stream ended without completion metrics") }
                switch completion.finishReason {
                case .stop: break
                case .cancelled: throw CancellationError()
                case .length: throw IntelligenceError.generationFailed("the output token limit was reached; try a shorter request")
                case .timeout: throw IntelligenceError.generationFailed("the request timed out")
                }
                return GenerationResponse(text: text, model: model, metrics: completion, loadMetrics: load)
            } onCancel: {
                Task { await self.cancel(operation: id) }
            }
            if releaseModelAfterResponse { await runtime.unload() }
            // A cancellation that began during cleanup must finish before admission opens to another request.
            await cancellationTask?.value
            try check(operation: id)
            end(operation: id)
            return response
        } catch {
            await cancellationTask?.value
            await runtime.unload()
            // A cancellation handler may have entered while unload was suspended.
            await cancellationTask?.value
            let wasCancelled = cancellationRequested || unloading || Task.isCancelled
            end(operation: id)
            if wasCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Cancels the transaction and returns after its cleanup. Resident weights from an idle kept response stay resident.
    public func cancel() async {
        guard let id = operationID else { return }
        await cancel(operation: id)
        if operationID == id { await withCheckedContinuation { operationWaiters.append($0) } }
    }

    /// Keeps admission closed until both the runtime and the request transaction have released their work.
    public func unload() async {
        if unloading {
            await withCheckedContinuation { unloadWaiters.append($0) }
            return
        }
        unloading = true
        if operationID != nil { cancellationRequested = true }
        await runtime.unload()
        if operationID != nil { await withCheckedContinuation { operationWaiters.append($0) } }
        unloading = false
        let waiters = unloadWaiters; unloadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func check(operation id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id, !cancellationRequested, !unloading else { throw CancellationError() }
    }

    private func cancel(operation id: UUID) async {
        guard operationID == id else { return }
        cancellationRequested = true
        if cancellationTask == nil {
            let runtime = runtime
            cancellationTask = Task { await runtime.cancel() }
        }
        await cancellationTask?.value
    }

    private func end(operation id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        cancellationRequested = false
        cancellationTask = nil
        let waiters = operationWaiters; operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
