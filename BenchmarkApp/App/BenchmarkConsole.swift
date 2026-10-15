import SwiftUI
import UIKit
import OfflineIntelligence
import OfflineIntelligenceBenchmarks

struct BenchmarkConsole: View {
    @Bindable var controller: BenchmarkController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        ZStack {
            BenchBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    runInstrument
                    modelSelection
                    if let failure = controller.failure, !failure.isEmpty {
                        messagePanel(title: "Run needs attention", message: failure, symbol: "exclamationmark.triangle")
                    }
                    if !controller.isPhysicalDevice {
                        messagePanel(title: "Simulator preview", message: "Live inference runs on a physical iPhone. No simulator measurements are recorded.", symbol: "iphone")
                    }
                    if controller.interrupted {
                        messagePanel(title: "Interrupted run", message: "The last saved checkpoint is retained. A new benchmark starts a fresh run; incomplete attempts are visible in the report.", symbol: "pause.circle")
                    }
                    if let report = controller.report {
                        ForEach(report.modelRuns) { run in
                            modelResults(run)
                        }
                    }
                    protocolPanel
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(BenchTheme.ink)
        .safeAreaInset(edge: .bottom) { transport }
        .task { await controller.prepare() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.enteredBackground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            controller.receivedMemoryWarning()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Offline Intelligence")
                .font(.system(.title, design: .rounded, weight: .semibold))
            HStack(spacing: 8) {
                Label("MLX · Qwen3.5", systemImage: "cpu")
                Text("·")
                Text(controller.deviceName)
            }
            .font(.caption.monospaced())
            .foregroundStyle(BenchTheme.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var runInstrument: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEVICE BENCHMARK")
                        .font(.caption.monospaced())
                        .tracking(1.4)
                        .foregroundStyle(BenchTheme.secondary)
                    Text(controller.stage)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(controller.isRunning ? BenchTheme.amber : BenchTheme.ink)
                }
                Spacer(minLength: 8)
                Image(systemName: controller.isRunning ? "cpu.fill" : "cpu")
                    .font(.title2)
                    .foregroundStyle(controller.isRunning ? BenchTheme.amber : BenchTheme.cyan)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(controller.completedTrials)")
                    .font(.system(.largeTitle, design: .rounded, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(BenchTheme.cyan)
                Text("/ \(controller.plannedTrials) trials")
                    .font(.title3.monospaced())
                    .foregroundStyle(BenchTheme.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trials finished")
            .accessibilityValue("\(controller.completedTrials) of \(controller.plannedTrials)")
            ProgressView(value: controller.fractionComplete)
                .tint(BenchTheme.cyan)
                .accessibilityLabel("Benchmark progress")
            if controller.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.activeModelName)
                        .font(.subheadline)
                    if let fixtureID = controller.activeFixtureID {
                        Text(fixtureTitle(fixtureID))
                            .font(.caption)
                            .foregroundStyle(BenchTheme.secondary)
                    }
                }
            }
            Divider().overlay(.white.opacity(0.08))
            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 16) {
                MetricReadout(label: "Thermal state", value: controller.thermalState, unit: "")
                MetricReadout(label: "Current process", value: memory(controller.footprintBytes), unit: "MiB")
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [BenchTheme.metalLight, BenchTheme.metalDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(LinearGradient(colors: [.white.opacity(0.27), .white.opacity(0.035), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
        }
    }

    private var modelSelection: some View {
        BenchPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("MODELS")
                    .font(.caption.monospaced())
                    .tracking(1.2)
                    .foregroundStyle(BenchTheme.secondary)
                Picker("Models to benchmark", selection: $controller.selection) {
                    Text("Both").tag("both")
                    Text("2B").tag("2b")
                    Text("4B").tag("4b")
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRunning)
                ForEach(controller.installedModels) { model in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.available ? "checkmark.circle" : "arrow.down.circle")
                            .foregroundStyle(model.available ? BenchTheme.cyan : BenchTheme.amber)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.descriptor.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(model.available ? "Bundled · \(model.descriptor.quantizationBits)-bit · \(gibibytes(model.weightBytes)) GiB weights" : model.problem ?? "Unavailable")
                                .font(.caption)
                                .foregroundStyle(BenchTheme.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Runs entirely on this phone. The benchmark app includes the pinned model files.")
                    .font(.caption)
                    .foregroundStyle(BenchTheme.secondary)
            }
        }
    }

    private func modelResults(_ run: BenchmarkModelRun) -> some View {
        let summary = BenchmarkModelSummary(run)
        return BenchPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(run.model.displayName)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(statusLabel(run.status.rawValue))
                        .font(.caption.monospaced())
                        .foregroundStyle(run.status == .completed ? BenchTheme.cyan : BenchTheme.amber)
                }
                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 18) {
                    MetricReadout(label: "First token · median", value: number(summary.medianFirstTokenSeconds, digits: 2), unit: "s", accent: BenchTheme.cyan)
                    MetricReadout(label: "Decode · median", value: number(summary.medianTokensPerSecond, digits: 1), unit: "tok/s", accent: BenchTheme.cyan)
                    MetricReadout(label: "Load", value: number(summary.loadSeconds, digits: 2), unit: "s")
                    MetricReadout(label: "Peak process · sampled", value: memory(summary.largestPeakFootprintBytes), unit: "MiB")
                    MetricReadout(label: "Peak MLX allocation", value: memory(summary.largestMLXPeakAllocatedBytes), unit: "MiB", accent: BenchTheme.violet)
                    MetricReadout(label: "Objective pass", value: "\(summary.passedTrials) / \(summary.attemptedTrials)", unit: "trials")
                }
                if let error = run.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(BenchTheme.amber)
                }
                if let warmup = run.warmup {
                    Text("Warmup: \(statusLabel(warmup.status.rawValue).lowercased()) · excluded from medians")
                        .font(.caption)
                        .foregroundStyle(BenchTheme.secondary)
                }
                if !run.trials.isEmpty {
                    DisclosureGroup("Outputs and checks (\(run.trials.count))") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(run.trials) { trial in
                                attemptView(trial)
                            }
                        }
                        .padding(.top, 12)
                    }
                    .font(.subheadline)
                    .tint(BenchTheme.cyan)
                }
            }
        }
    }

    private func attemptView(_ attempt: BenchmarkAttempt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(fixtureTitle(attempt.fixtureID)) · \((attempt.repeatIndex ?? 0) + 1)")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Image(systemName: attempt.score?.passed == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(attempt.score?.passed == true ? BenchTheme.cyan : BenchTheme.amber)
                    .accessibilityLabel(attempt.score?.passed == true ? "All checks passed" : "Checks failed or incomplete")
            }
            Text(statusLabel(attempt.status.rawValue))
                .font(.caption.monospaced())
                .foregroundStyle(BenchTheme.secondary)
            Text(attempt.output.isEmpty ? "No output recorded." : attempt.output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(BenchTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
            if let score = attempt.score {
                ForEach(score.checks.indices, id: \.self) { index in
                    let check = score.checks[index]
                    Label("\(check.name): \(check.detail)", systemImage: check.passed ? "checkmark" : "xmark")
                        .font(.caption)
                        .foregroundStyle(check.passed ? BenchTheme.secondary : BenchTheme.amber)
                }
            }
            if let error = attempt.error {
                Text(error).font(.caption).foregroundStyle(BenchTheme.amber)
            }
            Divider().overlay(.white.opacity(0.08))
        }
    }

    private var protocolPanel: some View {
        BenchPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Measurement protocol", systemImage: "ruler")
                    .font(.subheadline.weight(.medium))
                Text("One load and excluded warmup per model, then six shared tasks repeated three times. Models run one at a time with temperature 0 and a fixed seed.")
                Text("First token includes prompt processing. Decode speed excludes the first token. Memory is sampled process footprint; MLX allocation is separate. Medians include completed trials only.")
                Text("Objective checks validate formats, supplied facts and writing constraints. They do not rate creative quality. Keep the app in the foreground; leaving it cancels the run and saves its checkpoint.")
            }
            .font(.caption)
            .foregroundStyle(BenchTheme.secondary)
        }
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if controller.isRunning { controller.cancel() } else { controller.start() }
                } label: {
                    Label(controller.isRunning ? "Cancel run" : "Run benchmark", systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(.headline, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Capsule())
                }
                .buttonStyle(.glassProminent)
                .tint(controller.isRunning ? BenchTheme.amber : BenchTheme.cyan)
                .disabled(!controller.isRunning && !controller.canRun)
                .accessibilityHint(controller.isRunning ? "Cancels computation and retains the last checkpoint" : "Runs the selected models with identical prompts")

                if let url = controller.exportURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline)
                            .frame(width: 52, height: 52)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Share benchmark JSON")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [BenchTheme.canvas.opacity(0), BenchTheme.canvas.opacity(0.95)], startPoint: .top, endPoint: .bottom))
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicType.isAccessibilitySize ? 1 : 2)
    }

    private func messagePanel(title: String, message: String, symbol: String) -> some View {
        BenchPanel {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(BenchTheme.amber)
                Text(message).font(.caption).foregroundStyle(BenchTheme.secondary)
            }
        }
    }

    private func fixtureTitle(_ id: String) -> String {
        controller.report?.plan.fixtures.first(where: { $0.id == id })?.title ?? BenchmarkSuite.standard.first(where: { $0.id == id })?.title ?? id
    }

    private func number(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", digits, value)
    }

    private func memory(_ bytes: Int?) -> String {
        bytes.map { String(format: "%.0f", Double($0) / 1_048_576) } ?? "—"
    }

    private func gibibytes(_ bytes: Int) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824)
    }

    private func statusLabel(_ value: String) -> String {
        switch value {
        case "tokenLimit": "Token limit reached"
        case "timedOut": "Timed out"
        default: value.capitalized
        }
    }
}
