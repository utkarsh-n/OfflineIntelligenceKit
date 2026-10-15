import Foundation

/// Objective checks only. This is not a judge of creative quality, helpfulness, or safety.
public struct BenchmarkFixture: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let system: String
    public let prompt: String
    public let maxOutputTokens: Int
    public let scoring: BenchmarkScoringRule

    public init(id: String, title: String, system: String = BenchmarkSuite.system,
                prompt: String, maxOutputTokens: Int, scoring: BenchmarkScoringRule) {
        self.id = id
        self.title = title
        self.system = system
        self.prompt = prompt
        self.maxOutputTokens = maxOutputTokens
        self.scoring = scoring
    }
}

public enum BenchmarkJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
}

public struct BenchmarkJSONField: Codable, Sendable, Equatable {
    public let key: String
    public let value: BenchmarkJSONValue
    public init(_ key: String, _ value: BenchmarkJSONValue) {
        self.key = key
        self.value = value
    }
}

public enum BenchmarkScoringRule: Codable, Sendable, Equatable {
    /// A single JSON object, exactly these keys, with exact scalar values and types.
    case exactJSONObject([BenchmarkJSONField])
    /// Each group is a set of alternative phrases; at least one phrase in every group must appear.
    case facts(requiredPhraseGroups: [[String]], forbiddenPhrases: [String], wordRange: ClosedRange<Int>)
    /// Mechanical checks for rewriting; no subjective claim about its writing quality.
    case constrainedText(requiredWords: [String], forbiddenPhrases: [String], wordRange: ClosedRange<Int>)
}

public enum BenchmarkSuite {
    public static let version = "offline-fixtures-v1"
    public static let system = "Follow the user's instructions exactly. Use only the supplied facts. Do not add introductions or markdown fences. Keep the answer within the requested format."
    public static let warmupPrompt = "Reply with exactly this one word: Ready"

    public static let standard: [BenchmarkFixture] = [
        .init(id: "extract-settings", title: "Extract instrument settings", prompt: "Extract the settings from this note. Return one JSON object with exactly these keys: instrument (string), tempo_bpm (number), swing_enabled (boolean). Note: The drum machine runs at 96 beats per minute. Swing is off. The instrument name is EightOhEight.", maxOutputTokens: 128,
              scoring: .exactJSONObject([.init("instrument", .string("EightOhEight")), .init("tempo_bpm", .number(96)), .init("swing_enabled", .boolean(false))])),
        .init(id: "classify-packet", title: "Classify a packet event", prompt: "A simulated sender transmits packet 17, waits for an acknowledgement, and reaches its timeout without receiving one. Allowed event labels: delivered, timeout, duplicate. Return exactly a JSON object with event (string) and packet_id (number). Choose the event matching this observation.", maxOutputTokens: 96,
              scoring: .exactJSONObject([.init("event", .string("timeout")), .init("packet_id", .number(17))])),
        .init(id: "circuit-arithmetic", title: "Compute supplied circuit facts", prompt: "Use only these equations: V = I * R and P = V * I. A modeled resistor has R = 12 ohms and current I = 0.5 amperes. Return exactly a JSON object with voltage_V (number) and power_W (number).", maxOutputTokens: 128,
              scoring: .exactJSONObject([.init("voltage_V", .number(6)), .init("power_W", .number(3))])),
        .init(id: "grounded-retry", title: "Explain a supplied simulation", prompt: "Explain the following simulated packet trace in 35 to 90 words. Trace facts: packet 4 reached the receiver; its acknowledgement was lost; the sender timed out; the sender retried once; the receiver recognized the retried packet as a duplicate and did not deliver it again. Include the lost acknowledgement, timeout, one retry, and duplicate detection. Do not claim that packet 4 was never received or that two retries occurred.", maxOutputTokens: 192,
              scoring: .facts(requiredPhraseGroups: [["acknowledgement was lost", "acknowledgment was lost", "lost acknowledgement", "lost acknowledgment"], ["timed out", "timeout"], ["retried once", "one retry", "single retry"], ["duplicate"]], forbiddenPhrases: ["never received", "two retries"], wordRange: 35...90)),
        .init(id: "creative-constraints", title: "Rewrite with mechanical constraints", prompt: "Rewrite this as a playful bedtime note in 25 to 45 words: The Sun is setting and it is time to sleep. Include the exact words Sun and sleep. Use plain text, no heading or bullet list. Do not mention an AI, assistant, or language model.", maxOutputTokens: 128,
              scoring: .constrainedText(requiredWords: ["Sun", "sleep"], forbiddenPhrases: ["as an ai", "assistant", "language model"], wordRange: 25...45)),
        .init(id: "spanish-extraction", title: "Extract multilingual facts", prompt: "Extrae datos de esta nota en español. Devuelve solo un objeto JSON con exactamente las claves city (string), count (number), transport (string). Traduce city y transport al inglés. Nota: En Madrid, tres estudiantes viajan en tren. Usa el número 3 para count.", maxOutputTokens: 128,
              scoring: .exactJSONObject([.init("city", .string("Madrid")), .init("count", .number(3)), .init("transport", .string("train"))]))
    ]
}
