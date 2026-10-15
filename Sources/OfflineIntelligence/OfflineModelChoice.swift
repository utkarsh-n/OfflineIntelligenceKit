import Foundation

/// The same explicit choice is used by every host app. Old or absent settings select 2B.
public enum OfflineModelChoice: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case qwen2B = "2b"
    case qwen4B = "4b"

    public static let defaultChoice = Self.qwen2B
    public static let preferenceKey = "offlineIntelligence.modelChoice"
    public var id: String { rawValue }
    public var descriptor: ModelDescriptor { self == .qwen2B ? ModelCatalog.qwen2B : ModelCatalog.qwen4B }
    public var resourceFolder: String { self == .qwen2B ? "qwen-2b" : "qwen-4b" }
    public var title: String { self == .qwen2B ? "Qwen 2B" : "Qwen 4B" }
    public var detail: String {
        self == .qwen2B ? "Default · faster, lower memory use" : "Optional · more memory, stronger prose constraints"
    }
    public static func persisted(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? defaultChoice
    }
    public func persist(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preferenceKey) }
}

/// Resolves local files only. A selected 4B model never silently falls back to 2B.
public enum LocalModelFiles {
    public static func directory(for choice: OfflineModelChoice, bundle: Bundle = .main) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return try directory(for: choice,
                             bundleModelRoot: bundle.resourceURL?.appendingPathComponent("Models", isDirectory: true),
                             importedModelRoot: documents?.appendingPathComponent("Models", isDirectory: true))
    }

    public static func directory(for choice: OfflineModelChoice, bundleModelRoot: URL?, importedModelRoot: URL?) throws -> URL {
        for root in [importedModelRoot, bundleModelRoot].compactMap({ $0 }) {
            guard root.isFileURL else { throw IntelligenceError.invalidModelDirectory("model roots must be local file URLs") }
            let candidate = root.appendingPathComponent(choice.resourceFolder, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        throw IntelligenceError.invalidModelDirectory("\(choice.title) is not installed. Supply its verified local folder in Models/\(choice.resourceFolder).")
    }
}
