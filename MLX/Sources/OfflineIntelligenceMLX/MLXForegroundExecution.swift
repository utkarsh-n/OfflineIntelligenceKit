import Foundation
import MLX
#if os(iOS)
import UIKit
#endif

/// iOS Metal execution is allowed only while the application is active. Mac execution stays allowed.
/// Read the gate directly from compute loops; do not synchronously dispatch to the main queue from MLX work.
public enum MLXForegroundExecution {
    /// Installs lifecycle observers and initializes the gate on the main actor before any model work is admitted.
    public static func prepare() async throws {
        try Task.checkCancellation()
        #if os(iOS)
        await MainActor.run { ForegroundState.shared.configureIfNeeded() }
        #endif
        try Task.checkCancellation()
        guard isAllowed else { throw CancellationError() }
    }

    /// This scalar read never needs the main actor and can be used between prefill/decode steps.
    public static var isAllowed: Bool {
        #if os(iOS)
        ForegroundState.shared.isAllowed
        #else
        true
        #endif
    }

    /// CPU work can always drain. The pinned MLX GPU barrier commits a command buffer, even after drained work,
    /// so it must not be submitted while UIKit reports an inactive/background transition.
    public static func synchronizeIfAllowed() {
        Stream.defaultStream(.cpu).synchronize()
        #if !targetEnvironment(simulator)
        if isAllowed { Stream.defaultStream(.gpu).synchronize() }
        #endif
    }
}

#if os(iOS)
/// The gate scalar is lock-protected; observer configuration is confined to the main actor.
/// UIKit lifecycle notifications update the scalar synchronously on their posting thread.
private final class ForegroundState: @unchecked Sendable {
    static let shared = ForegroundState()
    private let lock = NSLock()
    private var allowed = false
    private var configured = false
    private var observers: [NSObjectProtocol] = []

    var isAllowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed
    }
    private func setAllowed(_ value: Bool) {
        lock.lock(); allowed = value; lock.unlock()
    }

    @MainActor func configureIfNeeded() {
        guard !configured else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.setAllowed(false)
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.setAllowed(true)
            },
        ]
        setAllowed(UIApplication.shared.applicationState == .active)
        configured = true
        // Subsequent prepare() calls trust the notifications. Re-reading applicationState could reopen the gate
        // between willResignActive and UIKit's state transition while the property still reports .active.
    }
}
#endif
