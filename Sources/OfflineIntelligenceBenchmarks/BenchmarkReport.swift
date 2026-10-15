import Foundation
import OfflineIntelligence

public struct BenchmarkPlan: Codable, Sendable, Equatable {
    public let models: [ModelDescriptor]
    public let fixtures: [BenchmarkFixture]
    public let repeats: Int
    public let seed: UInt64
    public let suiteVersion: String
    public let temperature: Float
    public let topP: Float
    public let maxPromptTokens: Int
    public let maxContextTokens: Int
    public let timeoutSeconds: Double

    public init(models: [ModelDescriptor] = ModelCatalog.all,
                fixtures: [BenchmarkFixture] = BenchmarkSuite.standard,
                repeats: Int = 3, seed: UInt64 = 42,
                timeoutSeconds: Double = 120) {
        self.models = models
        self.fixtures = fixtures
        self.repeats = repeats
        self.seed = seed
        self.suiteVersion = BenchmarkSuite.version
        self.temperature = 0
        self.topP = 1
        self.maxPromptTokens = 2048
        self.maxContextTokens = 4096
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct BenchmarkDeviceMetadata: Codable, Sendable, Equatable {
    public let deviceModel: String
    public let deviceName: String?
    public let osVersion: String
    public let appVersion: String
    public let physicalDevice: Bool
    public let notes: [String]
    public init(deviceModel: String, deviceName: String? = nil, osVersion: String,
                appVersion: String, physicalDevice: Bool, notes: [String] = []) {
        self.deviceModel = deviceModel
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.physicalDevice = physicalDevice
        self.notes = notes
    }
}

public struct BenchmarkObservation: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let thermalState: String
    public let batteryLevel: Double?
    public let batteryState: String?
    public let lowPowerMode: Bool
    public let availableMemoryBytes: Int?
    public let footprintBytes: Int?
    public init(timestamp: Date = Date(), thermalState: String,
                batteryLevel: Double? = nil, batteryState: String? = nil,
                lowPowerMode: Bool = false, availableMemoryBytes: Int? = nil,
                footprintBytes: Int? = nil) {
        self.timestamp = timestamp
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.availableMemoryBytes = availableMemoryBytes
        self.footprintBytes = footprintBytes
    }
}

public enum BenchmarkRunStatus: String, Codable, Sendable {
    case running, completed, cancelled, failed
}

public enum BenchmarkAttemptStatus: String, Codable, Sendable {
    case running, completed, tokenLimit, cancelled, timedOut, failed, interrupted
}

public struct BenchmarkAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let fixtureID: String
    /// Zero-based, and nil for the excluded warmup.
    public let repeatIndex: Int?
    public let request: GenerationRequest
    public let startedAt: Date
    public var finishedAt: Date?
    public let startObservation: BenchmarkObservation
    public var finishObservation: BenchmarkObservation?
    public var output: String
    public var metrics: GenerationMetrics?
    public var status: BenchmarkAttemptStatus
    public var error: String?
    public var score: BenchmarkScore?

    public init(fixtureID: String, repeatIndex: Int?, request: GenerationRequest,
                startObservation: BenchmarkObservation) {
        self.id = UUID()
        self.fixtureID = fixtureID
        self.repeatIndex = repeatIndex
        self.request = request
        self.startedAt = Date()
        self.finishedAt = nil
        self.startObservation = startObservation
        self.finishObservation = nil
        self.output = ""
        self.metrics = nil
        self.status = .running
        self.error = nil
        self.score = nil
    }
}

public struct BenchmarkModelRun: Codable, Sendable, Equatable, Identifiable {
    public var id: String { model.id }
    public let model: ModelDescriptor
    public let orderIndex: Int
    public var loadStartedAt: Date?
    public var loadFinishedAt: Date?
    public var loadStartObservation: BenchmarkObservation?
    public var loadFinishObservation: BenchmarkObservation?
    public var loadMetrics: ModelLoadMetrics?
    public var loadError: String?
    public var warmup: BenchmarkAttempt?
    public var trials: [BenchmarkAttempt]
    public var status: BenchmarkRunStatus

    public init(model: ModelDescriptor, orderIndex: Int) {
        self.model = model
        self.orderIndex = orderIndex
        self.trials = []
        self.status = .running
    }
}

public struct BenchmarkReport: Codable, Sendable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public var finishedAt: Date?
    public var status: BenchmarkRunStatus
    public let plan: BenchmarkPlan
    public let device: BenchmarkDeviceMetadata
    public var modelRuns: [BenchmarkModelRun]
    public var error: String?

    public init(plan: BenchmarkPlan, device: BenchmarkDeviceMetadata) {
        self.schemaVersion = 1
        self.id = UUID()
        self.createdAt = Date()
        self.finishedAt = nil
        self.status = .running
        self.plan = plan
        self.device = device
        self.modelRuns = []
        self.error = nil
    }

    public var completedTrialCount: Int {
        modelRuns.reduce(0) { $0 + $1.trials.filter { $0.status != .running }.count }
    }
    public var plannedTrialCount: Int { plan.models.count * plan.fixtures.count * max(0, plan.repeats) }
    public var summaries: [BenchmarkModelSummary] { modelRuns.map(BenchmarkModelSummary.init) }

    /// Recover a checkpoint left by process termination. No unobserved finish time or metrics are invented.
    public mutating func markInterrupted(reason: String) {
        guard status == .running else { return }
        status = .failed
        error = reason
        for modelIndex in modelRuns.indices {
            if modelRuns[modelIndex].status == .running { modelRuns[modelIndex].status = .failed }
            if var warmup = modelRuns[modelIndex].warmup, warmup.status == .running {
                warmup.status = .interrupted
                warmup.error = reason
                modelRuns[modelIndex].warmup = warmup
            }
            for trialIndex in modelRuns[modelIndex].trials.indices {
                if modelRuns[modelIndex].trials[trialIndex].status == .running {
                    modelRuns[modelIndex].trials[trialIndex].status = .interrupted
                    modelRuns[modelIndex].trials[trialIndex].error = reason
                    modelRuns[modelIndex].trials[trialIndex].score = .init(
                        checks: [.init(name: "complete generation", passed: false, detail: reason)],
                        disposition: .interrupted)
                }
            }
        }
    }
}

public struct BenchmarkModelSummary: Codable, Sendable, Equatable, Identifiable {
    public let modelID: String
    public var id: String { modelID }
    public let attemptedTrials: Int
    public let completedTrials: Int
    public let passedTrials: Int
    public let failedOrIncompleteTrials: Int
    public let medianFirstTokenSeconds: Double?
    public let medianGenerationSeconds: Double?
    public let medianTokensPerSecond: Double?
    public let largestPeakFootprintBytes: Int?
    public let largestMLXPeakAllocatedBytes: Int?
    public let loadSeconds: Double?
    /// Arithmetic mean of mechanical score fractions; no semantic quality rating.
    public let meanObjectiveScore: Double?

    public init(_ run: BenchmarkModelRun) {
        self.modelID = run.model.id
        self.attemptedTrials = run.trials.count
        let finished = run.trials.filter { $0.status != .running }
        let completed = run.trials.filter { $0.status == .completed }
        self.completedTrials = completed.count
        self.passedTrials = finished.filter { $0.score?.passed == true }.count
        self.failedOrIncompleteTrials = run.trials.count - completed.count
        // Performance medians include only completed, measured trials; warmup is excluded.
        let metrics = completed.compactMap(\.metrics)
        self.medianFirstTokenSeconds = BenchmarkStatistics.median(metrics.compactMap(\.firstTokenSeconds))
        self.medianGenerationSeconds = BenchmarkStatistics.median(metrics.map(\.generationSeconds))
        self.medianTokensPerSecond = BenchmarkStatistics.median(metrics.map(\.tokensPerSecond))
        self.largestPeakFootprintBytes = run.trials.compactMap { $0.metrics?.peakFootprintBytes }.max()
        self.largestMLXPeakAllocatedBytes = run.trials.compactMap { $0.metrics?.mlxPeakAllocatedBytes }.max()
        self.loadSeconds = run.loadMetrics?.durationSeconds
        let fractions = finished.compactMap { $0.score?.fraction }
        self.meanObjectiveScore = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
    }
}

public enum BenchmarkStatistics {
    /// Non-finite samples are invalid measurements and are omitted.
    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
    }
}

public struct BenchmarkProgress: Sendable {
    public let stage: String
    public let modelID: String?
    public let fixtureID: String?
    public let repeatIndex: Int?
    public let completedTrials: Int
    public let totalTrials: Int
    public init(stage: String, modelID: String? = nil, fixtureID: String? = nil,
                repeatIndex: Int? = nil, completedTrials: Int, totalTrials: Int) {
        self.stage = stage
        self.modelID = modelID
        self.fixtureID = fixtureID
        self.repeatIndex = repeatIndex
        self.completedTrials = completedTrials
        self.totalTrials = totalTrials
    }
}
