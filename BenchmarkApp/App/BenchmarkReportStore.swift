import Foundation
import OfflineIntelligenceBenchmarks

/// Every checkpoint replaces both a named run file and latest.json atomically.
/// An abruptly terminated process retains the most recent finished trial.
actor BenchmarkReportStore {
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("BenchmarkReports", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func save(_ report: BenchmarkReport) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(report)
        let runURL = directory.appendingPathComponent("\(report.id).json")
        try data.write(to: runURL, options: .atomic)
        try data.write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
        return runURL
    }

    func latest() throws -> (BenchmarkReport, URL)? {
        let url = directory.appendingPathComponent("latest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
        return (report, directory.appendingPathComponent("\(report.id).json"))
    }
}
