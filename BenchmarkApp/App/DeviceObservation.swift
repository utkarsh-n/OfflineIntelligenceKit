import Foundation
import UIKit
import Darwin
import os
import OfflineIntelligence
import OfflineIntelligenceBenchmarks

enum DeviceObservation {
    @MainActor
    static func metadata() -> BenchmarkDeviceMetadata {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return BenchmarkDeviceMetadata(
            deviceModel: machineIdentifier,
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            appVersion: "\(version) (\(build))",
            physicalDevice: isPhysicalDevice,
            notes: [
                "Backend pins: mlx-swift 0.32.3; mlx-swift-lm 3.32.3; swift-transformers Tokenizers 1.3.0.",
                "MLX reusable buffer cache cap: 16 MiB (16,777,216 bytes).",
                "Text-only inference with enable_thinking=false; no image or audio inputs.",
                "First token latency includes prompt processing after model load.",
                "Process memory includes app, runtime, model and cache; MLX allocation is reported separately.",
                "Physical process footprint is sampled every 25 milliseconds during generation; peaks are sampled values, not a continuous maximum.",
                "An iOS memory warning cancels the active run and unloads the resident model.",
                "Temperature 0, fixed seed, shared prompts and token limits; objective checks are fixture checks, not a general quality rating."
            ]
        )
    }

    @MainActor
    static func sample() -> BenchmarkObservation {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery: Double? = device.batteryLevel < 0 ? nil : Double(device.batteryLevel)
        let state: String
        switch device.batteryState {
        case .unknown: state = "unknown"
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        @unknown default: state = "unknown"
        }
        return BenchmarkObservation(
            thermalState: thermalName(ProcessInfo.processInfo.thermalState),
            batteryLevel: battery,
            batteryState: state,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            availableMemoryBytes: availableMemoryBytes,
            footprintBytes: processFootprintBytes()
        )
    }

    static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private static var availableMemoryBytes: Int? {
        #if targetEnvironment(simulator)
        nil
        #else
        Int(os_proc_available_memory())
        #endif
    }

    static var machineIdentifier: String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func processFootprintBytes() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : nil
    }
}
