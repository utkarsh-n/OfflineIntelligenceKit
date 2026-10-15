import SwiftUI

@main
struct OfflineIntelligenceBenchApp: App {
    @State private var controller = BenchmarkController()

    var body: some Scene {
        WindowGroup {
            BenchmarkConsole(controller: controller)
                .preferredColorScheme(.dark)
        }
    }
}
