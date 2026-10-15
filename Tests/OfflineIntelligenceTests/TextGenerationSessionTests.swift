import Foundation
import Testing
@testable import OfflineIntelligence

private let sessionRequest = GenerationRequest(prompt: "Return a short greeting.")
private let sessionDirectory = URL(fileURLWithPath: "/local/models/qwen-2b")

private func sessionMetrics(_ reason: GenerationFinishReason = .stop) -> GenerationMetrics {
    GenerationMetrics(promptTokens: 24, generatedTokens: 3, firstTokenSeconds: 0.1,
                      generationSeconds: 0.3, decodeSeconds: 0.2,
                      peakFootprintBytes: 1000, mlxPeakAllocatedBytes: 500, finishReason: reason)
}

@Suite("Complete text transactions")
struct TextGenerationSessionTests {
    @Test func completeResponseStreamsInOrderAndReleasesWeights() async throws {
        let runtime = SessionRuntime(events: [.chunk("Hel"), .chunk("lo 👋"), .completed(sessionMetrics())])
        let session = TextGenerationSession(runtime: runtime)
        let chunks = SessionChunks()
        let response = try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B,
                                                 directory: sessionDirectory, onText: { chunks.append($0) })
        #expect(response.text == "Hello 👋")
        #expect(chunks.values == ["Hel", "lo 👋"])
        #expect(response.model == ModelCatalog.qwen2B)
        #expect(response.loadMetrics?.modelID == ModelCatalog.qwen2B.id)
        #expect(response.metrics == sessionMetrics())
        #expect(await runtime.calls() == ["snapshot", "load", "generate", "unload-start", "unload-end"])
        #expect(await runtime.snapshot().state == .unloaded)
    }

    @Test func retainedModelIsReusedOnlyWhenReadyAndExplicitUnloadReleasesIt() async throws {
        let runtime = SessionRuntime()
        let session = TextGenerationSession(runtime: runtime)
        _ = try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory,
                                      releaseModelAfterResponse: false)
        let second = try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory,
                                               releaseModelAfterResponse: false)
        #expect(second.loadMetrics == nil)
        #expect(await runtime.calls().filter { $0 == "load" }.count == 1)
        #expect(await runtime.calls().filter { $0 == "unload-start" }.isEmpty)
        await session.unload()
        #expect(await runtime.snapshot().state == .unloaded)
    }

    @Test func missingDuplicateOrLateCompletionNeverBecomesAResponse() async {
        let scripts: [[GenerationEvent]] = [
            [.chunk("partial")],
            [.chunk("hello"), .completed(sessionMetrics()), .completed(sessionMetrics())],
            [.chunk("hello"), .completed(sessionMetrics()), .chunk(" late")],
        ]
        for events in scripts {
            let runtime = SessionRuntime(events: events)
            let session = TextGenerationSession(runtime: runtime)
            await expectSessionFailure {
                try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory)
            }
            #expect(await runtime.calls().last == "unload-end")
        }
    }

    @Test func outputLimitAndTimeoutRejectEvenPlausibleCompleteText() async {
        for reason in [GenerationFinishReason.length, .timeout] {
            let runtime = SessionRuntime(events: [.chunk("a valid looking answer"), .completed(sessionMetrics(reason))])
            let session = TextGenerationSession(runtime: runtime)
            await expectSessionFailure {
                try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory)
            }
            #expect(await runtime.calls().last == "unload-end")
        }
    }

    @Test func cancelledCompletionThrowsCancellationAndReleasesWeights() async {
        let runtime = SessionRuntime(events: [.chunk("partial"), .completed(sessionMetrics(.cancelled))])
        let session = TextGenerationSession(runtime: runtime)
        let response = Task { try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory) }
        await expectSessionCancellation(response)
        #expect(await runtime.calls().last == "unload-end")
    }

    @Test func responseByteBudgetStopsBeforePublishingAnOversizedChunk() async {
        let runtime = SessionRuntime(events: [.chunk(String(repeating: "x", count: 128 * 1024 + 1)), .completed(sessionMetrics())])
        let session = TextGenerationSession(runtime: runtime)
        let chunks = SessionChunks()
        await expectSessionFailure {
            try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B,
                                      directory: sessionDirectory, onText: { chunks.append($0) })
        }
        #expect(chunks.values.isEmpty)
        #expect(await runtime.calls().last == "unload-end")
    }

    @Test func callerCancellationWhileLoadingDrainsBeforeTheNextRequest() async throws {
        let loadGate = SessionGate()
        let runtime = SessionRuntime(loadGate: loadGate)
        let session = TextGenerationSession(runtime: runtime)
        let response = Task { try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory) }
        await loadGate.entered()
        response.cancel()
        await expectSessionCancellation(response)
        #expect(await runtime.calls().contains("cancel-end"))
        #expect(!((await runtime.calls()).contains("generate")))
        #expect(await runtime.calls().last == "unload-end")
        let next = try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory)
        #expect(next.text == "hello")
    }

    @Test func explicitCancellationDuringSnapshotCannotStartLaterGenerationOrEscapeCleanup() async throws {
        let snapshotGate = SessionGate(), cancelGate = SessionGate()
        let runtime = SessionRuntime(snapshotGate: snapshotGate, cancelGate: cancelGate)
        let session = TextGenerationSession(runtime: runtime)
        let finished = SessionFlag()
        let response = Task { try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory) }
        await snapshotGate.entered()
        let cancellation = Task { await session.cancel(); await finished.mark() }
        await cancelGate.entered()
        // The snapshot can now return, but a suspended backend cancellation still owns the transaction.
        await snapshotGate.open()
        #expect(await finished.value == false)
        await expectSessionBusy(session)
        await cancelGate.open()
        await expectSessionCancellation(response)
        await cancellation.value
        #expect(await finished.value)
        let calls = await runtime.calls()
        #expect(!calls.contains("load"))
        #expect(!calls.contains("generate"))
        #expect(calls.last == "unload-end")
        #expect(try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory).text == "hello")
    }

    @Test func cancellationDuringSuccessfulCleanupStillRejectsTheResponse() async {
        let unloadGate = SessionGate()
        let runtime = SessionRuntime(unloadGate: unloadGate)
        let session = TextGenerationSession(runtime: runtime)
        let response = Task { try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory) }
        await unloadGate.entered()
        response.cancel()
        await expectSessionBusy(session)
        await unloadGate.open()
        await expectSessionCancellation(response)
        #expect(await runtime.calls().last == "unload-end")
    }

    @Test func unloadKeepsAdmissionClosedAndConcurrentCallersWaitForDrain() async throws {
        let unloadGate = SessionGate()
        let runtime = SessionRuntime(unloadGate: unloadGate)
        let session = TextGenerationSession(runtime: runtime)
        _ = try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B,
                                      directory: sessionDirectory, releaseModelAfterResponse: false)
        let first = Task { await session.unload() }
        await unloadGate.entered()
        let second = Task { await session.unload() }
        await expectSessionBusy(session)
        await unloadGate.open()
        await first.value
        await second.value
        #expect(await runtime.peakConcurrentUnloads == 1)
        #expect(try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory).text == "hello")
    }

    @Test func unloadDuringPreloadSnapshotStopsTheRequestBeforeAnyLoad() async throws {
        let snapshotGate = SessionGate()
        let runtime = SessionRuntime(snapshotGate: snapshotGate)
        let session = TextGenerationSession(runtime: runtime)
        let response = Task { try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory) }
        await snapshotGate.entered()
        let unload = Task { await session.unload() }
        await runtime.called("unload-end")
        await expectSessionBusy(session)
        await snapshotGate.open()
        await expectSessionCancellation(response)
        await unload.value
        let calls = await runtime.calls()
        #expect(!calls.contains("load"))
        #expect(!calls.contains("generate"))
        #expect(try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory).text == "hello")
    }
}

private func expectSessionFailure(_ operation: @Sendable () async throws -> GenerationResponse) async {
    do { _ = try await operation(); Issue.record("An incomplete or invalid stream was accepted") }
    catch let error as IntelligenceError {
        if case .generationFailed = error {} else { Issue.record("Unexpected intelligence error: \(error)") }
    } catch { Issue.record("Unexpected error: \(error)") }
}
private func expectSessionCancellation(_ response: Task<GenerationResponse, any Error>) async {
    do { _ = try await response.value; Issue.record("A cancelled transaction returned a response") }
    catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
}
private func expectSessionBusy(_ session: TextGenerationSession) async {
    do {
        _ = try await session.respond(to: sessionRequest, model: ModelCatalog.qwen2B, directory: sessionDirectory)
        Issue.record("A new request entered while cleanup was pending")
    } catch let error as IntelligenceError { #expect(error == .busy) }
    catch { Issue.record("Unexpected admission error: \(error)") }
}

private actor SessionGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        hasEntered = true
        let ready = observers; observers.removeAll(); ready.forEach { $0.resume() }
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }
    func entered() async { if !hasEntered { await withCheckedContinuation { observers.append($0) } } }
    func open() { isOpen = true; let ready = waiters; waiters.removeAll(); ready.forEach { $0.resume() } }
}
private actor SessionFlag {
    private(set) var value = false
    func mark() { value = true }
}
private final class SessionChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    func append(_ chunk: String) { lock.lock(); chunks.append(chunk); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return chunks }
}

/// Gates are deterministic scheduling boundaries; the tests do not rely on sleeps or GPU infrastructure.
private actor SessionRuntime: IntelligenceRuntime {
    private let events: [GenerationEvent]
    private let snapshotGate: SessionGate?
    private let loadGate: SessionGate?
    private let unloadGate: SessionGate?
    private let cancelGate: SessionGate?
    private var history: [String] = []
    private var observers: [(String, CheckedContinuation<Void, Never>)] = []
    private var state: RuntimeState = .unloaded
    private var model: ModelDescriptor?
    private var loading = false
    private var cancelLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeUnloads = 0
    private(set) var peakConcurrentUnloads = 0

    init(events: [GenerationEvent] = [.chunk("hello"), .completed(sessionMetrics())],
         snapshotGate: SessionGate? = nil, loadGate: SessionGate? = nil,
         unloadGate: SessionGate? = nil, cancelGate: SessionGate? = nil) {
        self.events = events; self.snapshotGate = snapshotGate; self.loadGate = loadGate
        self.unloadGate = unloadGate; self.cancelGate = cancelGate
    }
    func calls() -> [String] { history }
    func called(_ name: String) async {
        if !history.contains(name) { await withCheckedContinuation { observers.append((name, $0)) } }
    }
    private func record(_ name: String) {
        history.append(name)
        let ready = observers.filter { $0.0 == name }
        observers.removeAll { $0.0 == name }
        ready.forEach { $0.1.resume() }
    }
    func load(model: ModelDescriptor, directory: URL) async throws -> ModelLoadMetrics {
        record("load")
        state = .loading; loading = true; cancelLoading = false
        defer {
            loading = false
            let ready = loadWaiters; loadWaiters.removeAll(); ready.forEach { $0.resume() }
        }
        await loadGate?.wait()
        guard !cancelLoading, !Task.isCancelled else { state = .unloaded; throw CancellationError() }
        self.model = model; state = .ready
        return ModelLoadMetrics(modelID: model.id, durationSeconds: 0.1,
                                footprintBeforeBytes: 100, footprintAfterBytes: 200, mlxActiveBytes: 100)
    }
    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        record("generate")
        guard model != nil else { throw IntelligenceError.modelNotLoaded }
        state = .generating
        let pair = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        events.forEach { pair.continuation.yield($0) }
        pair.continuation.finish()
        state = .ready
        return pair.stream
    }
    func cancel() async {
        record("cancel")
        await cancelGate?.wait()
        if loading {
            cancelLoading = true
            await loadGate?.open()
            if loading { await withCheckedContinuation { loadWaiters.append($0) } }
        }
        record("cancel-end")
    }
    func unload() async {
        activeUnloads += 1
        peakConcurrentUnloads = max(peakConcurrentUnloads, activeUnloads)
        defer { activeUnloads -= 1 }
        record("unload-start")
        if loading {
            cancelLoading = true
            await loadGate?.open()
            if loading { await withCheckedContinuation { loadWaiters.append($0) } }
        }
        await unloadGate?.wait()
        model = nil; state = .unloaded
        record("unload-end")
    }
    func snapshot() async -> RuntimeSnapshot {
        record("snapshot")
        await snapshotGate?.wait()
        return RuntimeSnapshot(state: state, model: model, footprintBytes: 200, mlxActiveBytes: 100, mlxCacheBytes: 0)
    }
}
