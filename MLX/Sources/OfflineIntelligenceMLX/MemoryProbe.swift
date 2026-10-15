import Foundation
import Darwin
import MLX
import OfflineIntelligence
#if os(iOS)
import os
#endif

/// Sampled process physical footprint is distinct from MLX's GPU allocator counters.
enum MemoryProbe {
    static var footprint: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : nil
    }
    static var available: Int? {
        #if os(iOS) && !targetEnvironment(simulator)
        return Int(os_proc_available_memory())
        #else
        return nil
        #endif
    }
    static func synchronize() {
        MLXForegroundExecution.synchronizeIfAllowed()
    }
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func elapsed(since start: UInt64) -> Double { Double(now - start) / 1_000_000_000 }
}

final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int?
    private let timer: DispatchSourceTimer
    init() {
        peak = MemoryProbe.footprint
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }
    private func sample() {
        guard let current = MemoryProbe.footprint else { return }
        lock.lock(); defer { lock.unlock() }
        peak = max(peak ?? 0, current)
    }
    func stop() -> Int? {
        timer.cancel()
        sample()
        lock.lock(); defer { lock.unlock() }
        return peak
    }
    deinit { timer.cancel() }
}

/// Cancellation can be signalled without waiting to enter the actor running a synchronous GPU/token loop.
final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopReason: GenerationFinishReason?
    private var interrupt: (@Sendable () -> Void)?
    func cancel() { stop(.cancelled) }
    func stop(_ reason: GenerationFinishReason) {
        lock.lock()
        if stopReason == nil { stopReason = reason }
        let handler = interrupt
        lock.unlock()
        handler?()
    }
    func register(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); interrupt = handler; let alreadyStopped = stopReason != nil; lock.unlock()
        if alreadyStopped { handler() }
    }
    func clearHandler() { lock.lock(); interrupt = nil; lock.unlock() }
    var reason: GenerationFinishReason? { lock.lock(); defer { lock.unlock() }; return stopReason }
    var isCancelled: Bool { reason != nil }
}

/// MLX configuration and allocation counters are process-global. At most one runtime may own weights in a process.
final class MLXLease: @unchecked Sendable {
    static let shared = MLXLease()
    private let lock = NSLock()
    private var owner: UUID?
    func acquire(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil || owner == id else { return false }
        owner = id
        return true
    }
    func release(_ id: UUID) { lock.lock(); defer { lock.unlock() }; if owner == id { owner = nil } }
}
