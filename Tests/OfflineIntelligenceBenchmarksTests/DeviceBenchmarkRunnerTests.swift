import Foundation
import XCTest
import OfflineIntelligence
@testable import OfflineIntelligenceBenchmarks

final class DeviceBenchmarkRunnerTests: XCTestCase, @unchecked Sendable {
    private let device = BenchmarkDeviceMetadata(deviceModel: "test-host", osVersion: "test", appVersion: "test", physicalDevice: false)
    private let observation = BenchmarkObservation(thermalState: "nominal", batteryLevel: 0.8)

    func testSerialOrderWarmupExclusionSettingsAndFullReportRoundTrip() async throws {
        let runtime = FakeRuntime()
        let checkpoints = Checkpoints()
        let models = ModelCatalog.all
        let plan = BenchmarkPlan(models: models, fixtures: [BenchmarkSuite.standard[0]], repeats: 3)
        let obs = observation
        let report = try await DeviceBenchmarkRunner(runtime: runtime).run(
            plan: plan, modelDirectories: Dictionary(uniqueKeysWithValues: models.map { ($0.id, URL(fileURLWithPath: "/models/\($0.id)")) }),
            device: device, observe: { obs }, checkpoint: { try await checkpoints.save($0) })
        XCTAssertEqual(report.status, .completed)
        XCTAssertEqual(report.completedTrialCount, 6)
        XCTAssertEqual(report.plannedTrialCount, 6)
        XCTAssertEqual(report.modelRuns.map(\.orderIndex), [0, 1])
        XCTAssertEqual(report.modelRuns.map { $0.model.revision }, models.map(\.revision))
        XCTAssertTrue(report.summaries.allSatisfy { $0.attemptedTrials == 3 && $0.passedTrials == 3 })
        XCTAssertTrue(report.summaries.allSatisfy { $0.medianGenerationSeconds == 2 })
        let calls = await runtime.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("load:") }, models.map { "load:\($0.id)" })
        XCTAssertEqual(calls.filter { $0 == "unload" }.count, 2)
        let requests = await runtime.requests
        XCTAssertEqual(requests.count, 8)
        XCTAssertTrue(requests.allSatisfy { $0.temperature == 0 && $0.topP == 1 && $0.seed == 42 })
        XCTAssertEqual(requests.filter { $0.prompt == BenchmarkSuite.warmupPrompt }.count, 2)
        XCTAssertTrue(requests.filter { $0.prompt != BenchmarkSuite.warmupPrompt }.allSatisfy { $0.maxOutputTokens == 128 })
        let saved = await checkpoints.reports
        XCTAssertTrue(saved.contains { $0.modelRuns.first?.trials.first?.status == .running })
        XCTAssertEqual(saved.last, report)
        let restored = try JSONDecoder().decode(BenchmarkReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored, report)
        XCTAssertEqual(restored.modelRuns[0].trials[0].request.prompt, BenchmarkSuite.standard[0].prompt)
        XCTAssertEqual(restored.modelRuns[0].trials[0].output, FakeRuntime.answer)
    }

    func testLengthLimitedOutputFailsScoreAndIsExcludedFromPerformanceMedian() async throws {
        let runtime = FakeRuntime(trialFinishReason: .length)
        let report = try await singleTrial(runtime)
        let trial = try XCTUnwrap(report.modelRuns.first?.trials.first)
        XCTAssertEqual(trial.status, .tokenLimit)
        XCTAssertEqual(trial.score?.fraction, 0)
        XCTAssertEqual(report.status, .failed)
        XCTAssertNil(report.summaries[0].medianGenerationSeconds)
        XCTAssertEqual(report.summaries[0].largestPeakFootprintBytes, 1234)
    }

    func testMissingCompletionIsRecordedAsFailure() async throws {
        let runtime = FakeRuntime(omitTrialCompletion: true)
        let report = try await singleTrial(runtime)
        let trial = try XCTUnwrap(report.modelRuns.first?.trials.first)
        XCTAssertEqual(trial.status, .failed)
        XCTAssertEqual(trial.output, FakeRuntime.answer)
        XCTAssertEqual(trial.score?.fraction, 0)
        XCTAssertNotNil(trial.error)
        XCTAssertEqual(report.status, .failed)
    }

    func testWarmupCancellationStopsBeforeTrialsAndUnloads() async throws {
        let runtime = FakeRuntime(cancelWarmup: true)
        let report = try await singleTrial(runtime)
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(report.modelRuns[0].warmup?.status, .cancelled)
        XCTAssertEqual(report.completedTrialCount, 0)
        XCTAssertEqual(report.modelRuns[0].trials.count, 0)
        let calls = await runtime.calls
        XCTAssertTrue(calls.contains("unload"))
    }

    func testCheckpointFailureStopsRunAndUnloadsRatherThanContinuing() async throws {
        let runtime = FakeRuntime()
        let checkpoints = Checkpoints(failOnSave: 4)
        let obs = observation
        do {
            _ = try await DeviceBenchmarkRunner(runtime: runtime).run(
                plan: .init(models: [ModelCatalog.qwen2B], fixtures: [BenchmarkSuite.standard[0]], repeats: 1),
                modelDirectories: [ModelCatalog.qwen2B.id: URL(fileURLWithPath: "/models")], device: device,
                observe: { obs }, checkpoint: { try await checkpoints.save($0) })
            XCTFail("Expected storage failure to stop the run")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checkpoint"))
        }
        let calls = await runtime.calls
        XCTAssertTrue(calls.contains("unload"))
        let requests = await runtime.requests
        XCTAssertTrue(requests.isEmpty)
        let reports = await checkpoints.reports
        XCTAssertEqual(reports.last?.status, .failed)
    }

    func testCrashRecoveryPreservesPartialOutputAndUnknownFinishTime() {
        let plan = BenchmarkPlan(models: [ModelCatalog.qwen2B], fixtures: [BenchmarkSuite.standard[0]], repeats: 1)
        var report = BenchmarkReport(plan: plan, device: device)
        var model = BenchmarkModelRun(model: ModelCatalog.qwen2B, orderIndex: 0)
        var trial = BenchmarkAttempt(fixtureID: plan.fixtures[0].id, repeatIndex: 0,
                                     request: .init(prompt: plan.fixtures[0].prompt), startObservation: observation)
        trial.output = "{\"instrument\":"
        model.trials = [trial]
        report.modelRuns = [model]
        report.markInterrupted(reason: "Recovered after a process restart")
        XCTAssertEqual(report.status, .failed)
        XCTAssertNil(report.finishedAt)
        XCTAssertEqual(report.modelRuns[0].status, .failed)
        XCTAssertEqual(report.modelRuns[0].trials[0].status, .interrupted)
        XCTAssertEqual(report.modelRuns[0].trials[0].output, "{\"instrument\":")
        XCTAssertNil(report.modelRuns[0].trials[0].finishedAt)
        XCTAssertNil(report.modelRuns[0].trials[0].metrics)
        XCTAssertEqual(report.modelRuns[0].trials[0].score?.fraction, 0)
    }

    private func singleTrial(_ runtime: FakeRuntime) async throws -> BenchmarkReport {
        let obs = observation
        return try await DeviceBenchmarkRunner(runtime: runtime).run(
            plan: .init(models: [ModelCatalog.qwen2B], fixtures: [BenchmarkSuite.standard[0]], repeats: 1),
            modelDirectories: [ModelCatalog.qwen2B.id: URL(fileURLWithPath: "/models")], device: device,
            observe: { obs }, checkpoint: { _ in })
    }
}

private actor Checkpoints {
    enum Failure: Error { case diskUnavailable }
    let failOnSave: Int?
    var saveCount = 0
    var reports: [BenchmarkReport] = []
    init(failOnSave: Int? = nil) { self.failOnSave = failOnSave }
    func save(_ report: BenchmarkReport) throws {
        saveCount += 1
        if saveCount == failOnSave { throw Failure.diskUnavailable }
        reports.append(report)
    }
}

private actor FakeRuntime: IntelligenceRuntime {
    static let answer = "{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"swing_enabled\":false}"
    let trialFinishReason: GenerationFinishReason
    let omitTrialCompletion: Bool
    let cancelWarmup: Bool
    var calls: [String] = []
    var requests: [GenerationRequest] = []
    init(trialFinishReason: GenerationFinishReason = .stop, omitTrialCompletion: Bool = false, cancelWarmup: Bool = false) {
        self.trialFinishReason = trialFinishReason
        self.omitTrialCompletion = omitTrialCompletion
        self.cancelWarmup = cancelWarmup
    }
    func load(model: ModelDescriptor, directory: URL) async throws -> ModelLoadMetrics {
        calls.append("load:\(model.id)")
        return .init(modelID: model.id, durationSeconds: 1, footprintBeforeBytes: 100, footprintAfterBytes: 200, mlxActiveBytes: 150)
    }
    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        let warmup = request.prompt == BenchmarkSuite.warmupPrompt
        let finish: GenerationFinishReason = warmup && cancelWarmup ? .cancelled : (warmup ? .stop : trialFinishReason)
        let omitted = !warmup && omitTrialCompletion
        return AsyncThrowingStream { continuation in
            continuation.yield(.chunk(warmup ? "Ready" : Self.answer))
            if !omitted {
                continuation.yield(.completed(.init(promptTokens: 30, generatedTokens: 21,
                                                    firstTokenSeconds: warmup ? 50 : 0.5,
                                                    generationSeconds: warmup ? 100 : 2,
                                                    decodeSeconds: 1.5, peakFootprintBytes: 1234,
                                                    mlxPeakAllocatedBytes: 900, finishReason: finish)))
            }
            continuation.finish()
        }
    }
    func cancel() async { calls.append("cancel") }
    func unload() async { calls.append("unload") }
    func snapshot() async -> RuntimeSnapshot { .init(state: .unloaded, model: nil, footprintBytes: nil, mlxActiveBytes: 0, mlxCacheBytes: 0) }
}
