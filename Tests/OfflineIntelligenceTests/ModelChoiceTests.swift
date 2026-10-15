import Foundation
import Testing
@testable import OfflineIntelligence

@Test func missingOrObsoletePreferencesDefaultTo2BAnd4BIsExplicit() throws {
    let defaults = try #require(UserDefaults(suiteName: "offline-tests-\(UUID().uuidString)"))
    defer { defaults.removeObject(forKey: OfflineModelChoice.preferenceKey) }
    #expect(OfflineModelChoice.persisted(in: defaults) == .qwen2B)
    defaults.set("old-gemma-writer", forKey: OfflineModelChoice.preferenceKey)
    #expect(OfflineModelChoice.persisted(in: defaults) == .qwen2B)
    OfflineModelChoice.qwen4B.persist(in: defaults)
    #expect(OfflineModelChoice.persisted(in: defaults) == .qwen4B)
    #expect(OfflineModelChoice.qwen4B.descriptor == ModelCatalog.qwen4B)
}

@Test func localModelsPreferImportedDirectoryAndNeverChangeSelectedModel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle", isDirectory: true)
    let imported = root.appendingPathComponent("imported", isDirectory: true)
    for folder in [bundle.appendingPathComponent("qwen-2b"), imported.appendingPathComponent("qwen-2b")] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    #expect(try LocalModelFiles.directory(for: .qwen2B, bundleModelRoot: bundle, importedModelRoot: imported) == imported.appendingPathComponent("qwen-2b", isDirectory: true))
    #expect(throws: IntelligenceError.self) {
        try LocalModelFiles.directory(for: .qwen4B, bundleModelRoot: bundle, importedModelRoot: imported)
    }
    #expect(throws: IntelligenceError.self) {
        try LocalModelFiles.directory(for: .qwen2B, bundleModelRoot: URL(string: "https://example.com/models"), importedModelRoot: nil)
    }
}
