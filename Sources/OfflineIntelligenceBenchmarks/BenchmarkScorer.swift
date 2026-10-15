import Foundation
import CoreFoundation

public enum BenchmarkOutputDisposition: String, Codable, Sendable {
    case completed, tokenLimit, cancelled, timedOut, error, interrupted
}

public struct BenchmarkCheck: Codable, Sendable, Equatable {
    public let name: String
    public let passed: Bool
    public let detail: String
    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public struct BenchmarkScore: Codable, Sendable, Equatable {
    public let checks: [BenchmarkCheck]
    public let disposition: BenchmarkOutputDisposition
    public var passed: Bool { disposition == .completed && !checks.isEmpty && checks.allSatisfy(\.passed) }
    /// Fraction of mechanical checks passed; a non-complete generation always scores zero.
    public var fraction: Double {
        guard disposition == .completed, !checks.isEmpty else { return 0 }
        return Double(checks.filter(\.passed).count) / Double(checks.count)
    }
    public init(checks: [BenchmarkCheck], disposition: BenchmarkOutputDisposition) {
        self.checks = checks
        self.disposition = disposition
    }
}

public enum BenchmarkScorer {
    public static func score(_ output: String, fixture: BenchmarkFixture,
                             disposition: BenchmarkOutputDisposition = .completed) -> BenchmarkScore {
        guard disposition == .completed else {
            return .init(checks: [.init(name: "complete generation", passed: false,
                                        detail: "Output ended as \(disposition.rawValue); partial output is not a valid answer.")], disposition: disposition)
        }
        switch fixture.scoring {
        case .exactJSONObject(let expected):
            return scoreJSON(output, expected: expected, disposition: disposition)
        case .facts(let groups, let forbidden, let range):
            let normalized = normalize(output)
            var checks = textChecks(output, forbidden: forbidden, range: range)
            for (index, group) in groups.enumerated() {
                let passed = group.contains { normalized.contains(normalize($0)) }
                checks.append(.init(name: "required fact \(index + 1)", passed: passed,
                                    detail: "Requires one of: \(group.joined(separator: " | ")). Phrase matching only; no semantic judge."))
            }
            return .init(checks: checks, disposition: disposition)
        case .constrainedText(let required, let forbidden, let range):
            let words = wordTokens(output)
            var checks = textChecks(output, forbidden: forbidden, range: range)
            for word in required {
                checks.append(.init(name: "required word \(word)", passed: words.contains(word),
                                    detail: "Requires the case-sensitive whole word \(word)."))
            }
            let plain = !output.contains("```") && !output.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
            }
            checks.append(.init(name: "plain text", passed: plain, detail: "No code fences, markdown headings, or bullet lines."))
            return .init(checks: checks, disposition: disposition)
        }
    }

    private static func scoreJSON(_ output: String, expected: [BenchmarkJSONField],
                                  disposition: BenchmarkOutputDisposition) -> BenchmarkScore {
        guard let data = output.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = parsed as? [String: Any] else {
            return .init(checks: [.init(name: "strict JSON object", passed: false,
                                        detail: "The entire output must be one valid JSON object, with no fences or surrounding prose.")], disposition: disposition)
        }
        var checks = [BenchmarkCheck(name: "strict JSON object", passed: true, detail: "Parsed the entire output as a JSON object.")]
        let sourceKeys = topLevelJSONKeys(output)
        checks.append(.init(name: "unique keys", passed: Set(sourceKeys).count == sourceKeys.count,
                            detail: "Duplicate JSON keys are rejected, including Unicode-escaped spellings."))
        let actualKeys = Set(object.keys)
        let expectedKeys = Set(expected.map(\.key))
        checks.append(.init(name: "exact keys", passed: actualKeys == expectedKeys,
                            detail: "Expected keys: \(expectedKeys.sorted().joined(separator: ", ")); actual: \(actualKeys.sorted().joined(separator: ", "))."))
        for field in expected {
            guard let actual = object[field.key] else {
                checks.append(.init(name: field.key, passed: false, detail: "Missing field."))
                continue
            }
            let matches: Bool
            switch field.value {
            case .string(let value): matches = (actual as? String) == value
            case .number(let value):
                if let number = actual as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    matches = number.doubleValue.isFinite && abs(number.doubleValue - value) <= max(1, abs(value)) * 1e-9
                } else { matches = false }
            case .boolean(let value):
                if let number = actual as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    matches = number.boolValue == value
                } else { matches = false }
            case .null: matches = actual is NSNull
            }
            checks.append(.init(name: field.key, passed: matches, detail: matches ? "Exact value and type match." : "Value or JSON scalar type differs from expectation."))
        }
        return .init(checks: checks, disposition: disposition)
    }

    private static func textChecks(_ output: String, forbidden: [String], range: ClosedRange<Int>) -> [BenchmarkCheck] {
        let wordCount = wordTokens(output).count
        let normalized = normalize(output)
        var checks = [BenchmarkCheck(name: "word count", passed: range.contains(wordCount),
                                     detail: "\(wordCount) words; allowed \(range.lowerBound)...\(range.upperBound).")]
        for phrase in forbidden {
            checks.append(.init(name: "excluded phrase \(phrase)", passed: !normalized.contains(normalize(phrase)),
                                detail: "Must not contain this literal phrase. This does not detect every possible unsupported claim."))
        }
        return checks
    }

    private static func wordTokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    private static func normalize(_ text: String) -> String {
        wordTokens(text).joined(separator: " ").lowercased()
    }

    // Foundation's parser accepts duplicate keys, so inspect keys in the already-validated object.
    private static func topLevelJSONKeys(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var keys: [String] = []
        var index = 0
        var depth = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91: depth += 1; index += 1 // { [
            case 125, 93: depth -= 1; index += 1 // } ]
            case 34:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue } // escaped character
                    if bytes[index] == 34 { index += 1; break }
                    index += 1
                }
                var next = index
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if depth == 1, next < bytes.count, bytes[next] == 58,
                   let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) {
                    keys.append(key)
                }
            default: index += 1
            }
        }
        return keys
    }
}
