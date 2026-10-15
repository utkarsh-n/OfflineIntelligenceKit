import Foundation
import Observation
import UIKit
import OfflineIntelligence
import OfflineIntelligenceMLX
import OfflineIntelligenceBenchmarks

struct InstalledBenchmarkModel: Identifiable {
    let descriptor: ModelDescriptor
    let directory: URL?
    let problem: String?
    let weightBytes: Int
    var id: String { descriptor.id }
    var available: Bool { directory != nil && problem == nil }
}

@MainActor
@Observable
final class BenchmarkController {
    private(set) var installedModels: [InstalledBenchmarkModel] = []
    private(set) var isRunning = false
    private(set) var stage = "Ready to measure"
    private(set) var activeModelID: String?
    private(set) var activeFixtureID: String?
    private(set) var completedTrials = 0
    private(set) var plannedTrials = 0
    private(set) var report: BenchmarkReport?
    private(set) var exportURL: URL?
    private(set) var failure: String?
    private(set) var interrupted = false
    private(set) var thermalState = "—"
    private(set) var footprintBytes: Int?
    var selection = "both" {
        didSet {
            if !isRunning && report == nil {
                plannedTrials = selectedModels.count * BenchmarkSuite.standard.count * 3
            }
        }
    }

    @ObservationIgnored private let runtime = MLXIntelligenceRuntime()
    @ObservationIgnored private let store = BenchmarkReportStore()
    @ObservationIgnored private lazy var runner = DeviceBenchmarkRunner(runtime: runtime)
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var didPrepare = false

    var deviceName: String { DeviceObservation.machineIdentifier }
    var isPhysicalDevice: Bool { DeviceObservation.isPhysicalDevice }
    var fractionComplete: Double {
        plannedTrials > 0 ? Double(completedTrials) / Double(plannedTrials) : 0
    }
    var activeModelName: String {
        installedModels.first(where: { $0.id == activeModelID })?.descriptor.displayName ?? "Qwen3.5"
    }
    var selectedModels: [InstalledBenchmarkModel] {
        installedModels.filter { selection == "both" || ($0.descriptor.parameterBillions == (selection == "2b" ? 2 : 4)) }
    }
    var canRun: Bool { isPhysicalDevice && !isRunning && !selectedModels.isEmpty && selectedModels.allSatisfy(\.available) }

    init() {
        installedModels = ModelCatalog.all.map(Self.inspect)
        plannedTrials = installedModels.count * BenchmarkSuite.standard.count * 3
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        updateObservation(DeviceObservation.sample())
        do {
            if var (saved, url) = try await store.latest() {
                interrupted = saved.status == .running
                if interrupted {
                    saved.markInterrupted(reason: "The previous app session ended before a final benchmark checkpoint. Its termination time is unknown; only saved observations are retained.")
                    url = try await store.save(saved)
                }
                report = saved
                exportURL = url
                completedTrials = saved.completedTrialCount
                plannedTrials = saved.plannedTrialCount
                stage = interrupted ? "Previous run interrupted" : "Saved run: \(saved.status.rawValue)"
            }
        } catch {
            failure = "The saved report could not be read: \(error.localizedDescription)"
        }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--model"), args.indices.contains(index + 1), ["2b", "4b"].contains(args[index + 1]) {
            selection = args[index + 1]
        }
        if args.contains("--benchmark") { start() }
    }

    func start() {
        guard !isRunning else { return }
        guard isPhysicalDevice else {
            failure = "Live inference is measured on a physical iPhone. This simulator can inspect the interface and saved reports."
            return
        }
        guard canRun else {
            failure = selectedModels.compactMap(\.problem).joined(separator: "\n")
            if failure?.isEmpty != false { failure = "No selected model is available." }
            return
        }
        let models = selectedModels
        let plan = BenchmarkPlan(models: models.map(\.descriptor))
        let directories = Dictionary(uniqueKeysWithValues: models.compactMap { model in
            model.directory.map { (model.id, $0) }
        })
        isRunning = true
        interrupted = false
        failure = nil
        report = nil
        exportURL = nil
        completedTrials = 0
        plannedTrials = plan.fixtures.count * plan.repeats * plan.models.count
        stage = "Preparing benchmark"
        activeModelID = nil
        activeFixtureID = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let device = DeviceObservation.metadata()
        let runner = self.runner
        let store = self.store

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner.run(
                    plan: plan,
                    modelDirectories: directories,
                    device: device,
                    observe: { await DeviceObservation.sample() },
                    checkpoint: { [weak self] report in
                        let url = try await store.save(report)
                        await self?.receiveCheckpoint(report, url: url)
                    },
                    progress: { [weak self] value in await self?.receiveProgress(value) }
                )
                report = result
                stage = result.status == .completed ? "Benchmark complete" : "Benchmark \(result.status.rawValue)"
            } catch is CancellationError {
                stage = "Benchmark interrupted"
                interrupted = true
            } catch {
                stage = "Benchmark stopped"
                failure = error.localizedDescription
            }
            await runtime.unload()
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
            updateObservation(DeviceObservation.sample())
            runTask = nil
        }
    }

    func cancel(reason: String = "Cancelled by you") {
        guard isRunning else { return }
        stage = reason
        interrupted = true
        runTask?.cancel()
        let runner = self.runner
        Task { await runner.cancel() }
    }

    func enteredBackground() {
        guard isRunning else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Save benchmark checkpoint")
        let interruptedTask = runTask
        cancel(reason: "Interrupted when app left the foreground")
        Task {
            await runner.cancel()
            await interruptedTask?.value
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
        }
    }

    func receivedMemoryWarning() {
        failure = "iOS reported memory pressure. The resident model is being released; saved benchmark checkpoints remain available."
        print("OFFLINE_BENCH_MEMORY_WARNING")
        if isRunning { cancel(reason: "Interrupted by iOS memory warning") }
        Task {
            await runner.cancel()
            await runtime.unload()
            updateObservation(DeviceObservation.sample())
        }
    }

    private func receiveProgress(_ progress: BenchmarkProgress) {
        stage = progress.stage
        activeModelID = progress.modelID
        activeFixtureID = progress.fixtureID
        completedTrials = progress.completedTrials
        plannedTrials = progress.totalTrials
        updateObservation(DeviceObservation.sample())
    }

    private func receiveCheckpoint(_ report: BenchmarkReport, url: URL) {
        self.report = report
        exportURL = url
        completedTrials = report.completedTrialCount
        plannedTrials = report.plannedTrialCount
        updateObservation(DeviceObservation.sample())
        print("OFFLINE_BENCH_CHECKPOINT \(report.status.rawValue) \(completedTrials)/\(plannedTrials) \(url.lastPathComponent)")
    }

    private func updateObservation(_ value: BenchmarkObservation) {
        thermalState = value.thermalState
        footprintBytes = value.footprintBytes
    }

    private static func inspect(_ descriptor: ModelDescriptor) -> InstalledBenchmarkModel {
        let folder = descriptor.parameterBillions == 2 ? "qwen-2b" : "qwen-4b"
        let root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let directory = root.appendingPathComponent("Models", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return InstalledBenchmarkModel(descriptor: descriptor, directory: nil, problem: "\(descriptor.displayName) model files are not installed.", weightBytes: 0)
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            let weights = files.filter { $0.pathExtension == "safetensors" }
            let bytes = try weights.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            let names = Set(files.map(\.lastPathComponent))
            guard names.contains("config.json"), names.contains("tokenizer.json"), !weights.isEmpty else {
                return InstalledBenchmarkModel(descriptor: descriptor, directory: directory, problem: "\(descriptor.displayName) model files are incomplete.", weightBytes: bytes)
            }
            let metadataURL = directory.appendingPathComponent("model-metadata.json")
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            guard metadata?["revision"] as? String == descriptor.revision,
                  metadata?["repositoryID"] as? String == descriptor.repositoryID,
                  metadata?["quantizationBits"] as? Int == descriptor.quantizationBits else {
                return InstalledBenchmarkModel(descriptor: descriptor, directory: directory, problem: "\(descriptor.displayName) revision does not match the benchmark catalog.", weightBytes: bytes)
            }
            return InstalledBenchmarkModel(descriptor: descriptor, directory: directory, problem: nil, weightBytes: bytes)
        } catch {
            return InstalledBenchmarkModel(descriptor: descriptor, directory: directory, problem: "\(descriptor.displayName): \(error.localizedDescription)", weightBytes: 0)
        }
    }
}
