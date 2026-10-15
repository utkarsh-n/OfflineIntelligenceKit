import Foundation
import OfflineIntelligence

public enum BenchmarkRunnerError: LocalizedError, Sendable {
    case alreadyRunning
    case invalidPlan(String)
    case missingModelDirectory(String)
    case missingCompletion

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A benchmark is already running."
        case .invalidPlan(let reason): "Invalid benchmark plan: \(reason)"
        case .missingModelDirectory(let modelID): "No local model directory supplied for \(modelID)."
        case .missingCompletion: "Generation stream ended without completion metrics."
        }
    }
}

/// Runs one model at a time. No downloads, networking, or device APIs are performed here.
public actor DeviceBenchmarkRunner {
    public typealias Observation = @Sendable () async -> BenchmarkObservation
    public typealias Checkpoint = @Sendable (BenchmarkReport) async throws -> Void
    public typealias Progress = @Sendable (BenchmarkProgress) async -> Void

    private let runtime: any IntelligenceRuntime
    private var activeReport: BenchmarkReport?
    private var isRunning = false
    private var cancellationRequested = false

    public init(runtime: any IntelligenceRuntime) { self.runtime = runtime }

    public func cancel() async {
        cancellationRequested = true
        await runtime.cancel()
    }

    public func run(plan: BenchmarkPlan, modelDirectories: [String: URL],
                    device: BenchmarkDeviceMetadata, observe: @escaping Observation,
                    checkpoint: @escaping Checkpoint,
                    progress: @escaping Progress = { _ in }) async throws -> BenchmarkReport {
        guard !isRunning else { throw BenchmarkRunnerError.alreadyRunning }
        try validate(plan)
        isRunning = true
        cancellationRequested = false
        activeReport = BenchmarkReport(plan: plan, device: device)
        defer { isRunning = false }

        do {
            try await checkpointReport(checkpoint)
            for (modelIndex, model) in plan.models.enumerated() {
                if shouldCancel { break }
                activeReport!.modelRuns.append(.init(model: model, orderIndex: modelIndex))
                let loadObservation = await observe()
                activeReport!.modelRuns[modelIndex].loadStartedAt = Date()
                activeReport!.modelRuns[modelIndex].loadStartObservation = loadObservation
                try await checkpointReport(checkpoint)
                await sendProgress("Loading model", modelID: model.id, progress: progress)
                do {
                    guard let directory = modelDirectories[model.id] else {
                        throw BenchmarkRunnerError.missingModelDirectory(model.id)
                    }
                    let load = try await runtime.load(model: model, directory: directory)
                    activeReport!.modelRuns[modelIndex].loadMetrics = load
                    activeReport!.modelRuns[modelIndex].loadFinishedAt = Date()
                    let loadEnd = await observe()
                    activeReport!.modelRuns[modelIndex].loadFinishObservation = loadEnd
                    try await checkpointReport(checkpoint)
                } catch {
                    if error is CheckpointFailure { throw error }
                    let cancelled = shouldCancel || error is CancellationError
                    cancellationRequested = cancelled
                    activeReport!.modelRuns[modelIndex].loadFinishedAt = Date()
                    activeReport!.modelRuns[modelIndex].loadError = error.localizedDescription
                    let observation = await observe()
                    activeReport!.modelRuns[modelIndex].loadFinishObservation = observation
                    activeReport!.modelRuns[modelIndex].status = cancelled ? .cancelled : .failed
                    try await checkpointReport(checkpoint)
                    await runtime.unload()
                    if cancelled { break }
                    continue
                }

                if !shouldCancel {
                    let request = makeRequest(prompt: BenchmarkSuite.warmupPrompt,
                                              system: BenchmarkSuite.system, maxOutputTokens: 32, plan: plan)
                    let observation = await observe()
                    activeReport!.modelRuns[modelIndex].warmup = .init(fixtureID: "warmup", repeatIndex: nil,
                                                                     request: request, startObservation: observation)
                    try await checkpointReport(checkpoint)
                    await sendProgress("Warmup (excluded)", modelID: model.id, progress: progress)
                    try await generate(at: .warmup(modelIndex), fixture: nil, observe: observe, checkpoint: checkpoint)
                }

                if !shouldCancel {
                    fixtureLoop: for fixture in plan.fixtures {
                        for repeatIndex in 0..<plan.repeats {
                            if shouldCancel { break fixtureLoop }
                            let request = makeRequest(prompt: fixture.prompt, system: fixture.system,
                                                      maxOutputTokens: fixture.maxOutputTokens, plan: plan)
                            let observation = await observe()
                            let trialIndex = activeReport!.modelRuns[modelIndex].trials.count
                            activeReport!.modelRuns[modelIndex].trials.append(.init(fixtureID: fixture.id,
                                                                                  repeatIndex: repeatIndex,
                                                                                  request: request,
                                                                                  startObservation: observation))
                            try await checkpointReport(checkpoint)
                            await sendProgress("Running trial", modelID: model.id, fixtureID: fixture.id,
                                               repeatIndex: repeatIndex, progress: progress)
                            try await generate(at: .trial(modelIndex, trialIndex), fixture: fixture,
                                               observe: observe, checkpoint: checkpoint)
                            await sendProgress("Trial saved", modelID: model.id, fixtureID: fixture.id,
                                               repeatIndex: repeatIndex, progress: progress)
                        }
                    }
                }
                let trials = activeReport!.modelRuns[modelIndex].trials
                let warmupFailed = activeReport!.modelRuns[modelIndex].warmup?.status != .completed
                activeReport!.modelRuns[modelIndex].status = shouldCancel ? .cancelled :
                    (warmupFailed || trials.contains { $0.status != .completed } ? .failed : .completed)
                await runtime.unload()
                try await checkpointReport(checkpoint)
                if shouldCancel { break }
            }
            activeReport!.finishedAt = Date()
            activeReport!.status = shouldCancel ? .cancelled :
                (activeReport!.modelRuns.contains { $0.status == .failed } ? .failed : .completed)
            try await checkpointReport(checkpoint)
            await sendProgress(shouldCancel ? "Cancelled" : "Finished", progress: progress)
            return activeReport!
        } catch {
            await runtime.cancel()
            await runtime.unload()
            activeReport!.markInterrupted(reason: error.localizedDescription)
            activeReport!.status = shouldCancel || error is CancellationError ? .cancelled : .failed
            activeReport!.finishedAt = Date()
            activeReport!.error = error.localizedDescription
            // A failed storage callback cannot be assumed to save this final update.
            try? await checkpointReport(checkpoint)
            throw error
        }
    }

    private enum AttemptLocation {
        case warmup(Int)
        case trial(Int, Int)
    }

    private func attempt(at location: AttemptLocation) -> BenchmarkAttempt {
        switch location {
        case .warmup(let index): activeReport!.modelRuns[index].warmup!
        case .trial(let model, let trial): activeReport!.modelRuns[model].trials[trial]
        }
    }

    private func setAttempt(_ attempt: BenchmarkAttempt, at location: AttemptLocation) {
        switch location {
        case .warmup(let index): activeReport!.modelRuns[index].warmup = attempt
        case .trial(let model, let trial): activeReport!.modelRuns[model].trials[trial] = attempt
        }
    }

    private func generate(at location: AttemptLocation, fixture: BenchmarkFixture?,
                          observe: Observation, checkpoint: Checkpoint) async throws {
        var record = attempt(at: location)
        var lastCheckpoint = Date()
        var streamFailure: Error?
        do {
            if shouldCancel { throw CancellationError() }
            let stream = try await runtime.generate(record.request)
            for try await event in stream {
                switch event {
                case .chunk(let text):
                    record.output += text
                    setAttempt(record, at: location)
                    // Preserve partial output without adding a disk write for every generated token.
                    if Date().timeIntervalSince(lastCheckpoint) >= 0.75 {
                        try await checkpointReport(checkpoint)
                        lastCheckpoint = Date()
                    }
                case .completed(let metrics):
                    record.metrics = metrics
                    switch metrics.finishReason {
                    case .stop: record.status = .completed
                    case .length: record.status = .tokenLimit
                    case .cancelled: record.status = .cancelled; cancellationRequested = true
                    case .timeout: record.status = .timedOut
                    }
                }
                if shouldCancel {
                    await runtime.cancel()
                }
            }
            if record.metrics == nil { throw BenchmarkRunnerError.missingCompletion }
        } catch {
            if error is CheckpointFailure {
                record.status = .interrupted
                record.finishedAt = Date()
                record.error = error.localizedDescription
                setAttempt(record, at: location)
                throw error
            }
            streamFailure = error
            record.error = error.localizedDescription
            if shouldCancel || error is CancellationError {
                record.status = .cancelled
                cancellationRequested = true
            } else {
                record.status = .failed
            }
        }
        record.finishedAt = Date()
        record.finishObservation = await observe()
        if let fixture {
            record.score = BenchmarkScorer.score(record.output, fixture: fixture, disposition: disposition(record.status))
        }
        setAttempt(record, at: location)
        try await checkpointReport(checkpoint)
        // Generation errors become recorded failed trials; storage errors must stop the run.
        if let streamFailure, streamFailure is CancellationError { cancellationRequested = true }
    }

    private var shouldCancel: Bool { cancellationRequested || Task.isCancelled }

    private func checkpointReport(_ checkpoint: Checkpoint) async throws {
        do {
            try await checkpoint(activeReport!)
        } catch {
            throw CheckpointFailure(detail: error.localizedDescription)
        }
    }

    private struct CheckpointFailure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Could not save benchmark checkpoint: \(detail)" }
    }

    private func sendProgress(_ stage: String, modelID: String? = nil, fixtureID: String? = nil,
                              repeatIndex: Int? = nil, progress: Progress) async {
        await progress(.init(stage: stage, modelID: modelID, fixtureID: fixtureID, repeatIndex: repeatIndex,
                             completedTrials: activeReport!.completedTrialCount,
                             totalTrials: activeReport!.plannedTrialCount))
    }

    private func makeRequest(prompt: String, system: String, maxOutputTokens: Int,
                             plan: BenchmarkPlan) -> GenerationRequest {
        .init(system: system, prompt: prompt, maxOutputTokens: maxOutputTokens,
              maxPromptTokens: plan.maxPromptTokens, maxContextTokens: plan.maxContextTokens,
              temperature: plan.temperature, topP: plan.topP, seed: plan.seed,
              timeoutSeconds: plan.timeoutSeconds)
    }

    private func validate(_ plan: BenchmarkPlan) throws {
        guard !plan.models.isEmpty, !plan.fixtures.isEmpty, plan.repeats > 0, plan.repeats <= 20,
              plan.timeoutSeconds.isFinite, (1...600).contains(plan.timeoutSeconds),
              Set(plan.models.map(\.id)).count == plan.models.count,
              Set(plan.fixtures.map(\.id)).count == plan.fixtures.count,
              plan.fixtures.allSatisfy({ !$0.id.isEmpty && !$0.prompt.isEmpty && $0.maxOutputTokens > 0 && $0.maxOutputTokens <= 1024 }) else {
            throw BenchmarkRunnerError.invalidPlan("Provide unique models and fixtures, 1...20 repeats, timeout in 1...600 seconds, and output limits in 1...1024.")
        }
    }

    private func disposition(_ status: BenchmarkAttemptStatus) -> BenchmarkOutputDisposition {
        switch status {
        case .completed: .completed
        case .tokenLimit: .tokenLimit
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .failed: .error
        case .running, .interrupted: .interrupted
        }
    }
}
