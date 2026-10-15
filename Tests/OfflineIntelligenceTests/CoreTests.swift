import Foundation
import Testing
@testable import OfflineIntelligence

@Test func pinnedCatalogHasDistinctCheckpointsAndRealBudgets() throws {
    #expect(ModelCatalog.all.count == 2)
    #expect(Set(ModelCatalog.all.map(\.id)).count == 2)
    for model in ModelCatalog.all {
        #expect(model.revision.count == 40)
        #expect(model.quantizationBits == 4)
        #expect(model.estimatedWeightBytes > 1_000_000_000)
        #expect(model.contextWindowTokens >= 16_384)
        let roundtrip = try JSONDecoder().decode(ModelDescriptor.self, from: JSONEncoder().encode(model))
        #expect(roundtrip == model)
    }
    #expect(ModelCatalog.qwen4B.estimatedWeightBytes > ModelCatalog.qwen2B.estimatedWeightBytes)
}

@Test func requestRejectsUnboundedOrNonsensicalWork() {
    for request in [
        GenerationRequest(prompt: " "),
        GenerationRequest(prompt: "a", maxOutputTokens: 0),
        GenerationRequest(prompt: "a", maxOutputTokens: 1025),
        GenerationRequest(prompt: "a", maxPromptTokens: 8193),
        GenerationRequest(prompt: "a", maxContextTokens: 16385),
        GenerationRequest(prompt: "a", temperature: .nan),
        GenerationRequest(prompt: "a", topP: 0),
        GenerationRequest(prompt: "a", timeoutSeconds: .infinity),
        GenerationRequest(prompt: String(repeating: "é", count: 70_000)),
    ] {
        #expect(throws: IntelligenceError.self) { try request.validate() }
    }
}

@Test func renderedTokensEnforceBothPromptAndContextIncludingSystemTemplate() throws {
    let request = GenerationRequest(prompt: "Explain gravity", maxOutputTokens: 128, maxPromptTokens: 512, maxContextTokens: 600)
    try request.validateTokenCount(472, model: ModelCatalog.qwen2B)
    #expect(throws: IntelligenceError.contextTooLong(actual: 601, limit: 600)) {
        try request.validateTokenCount(473, model: ModelCatalog.qwen2B)
    }
    #expect(throws: IntelligenceError.promptTooLong(actual: 513, limit: 512)) {
        try request.validateTokenCount(513, model: ModelCatalog.qwen2B)
    }
}

private struct Answer: Codable, Equatable { let label: String; let count: Int }
private enum ValidationFailure: Error { case negativeCount }

@Test func structuredOutputRequiresCompleteJSONAndApplicationValidation() throws {
    let expected = Answer(label: "packet", count: 3)
    let decoded = try StructuredOutput.decode("{\"label\":\"packet\",\"count\":3}", as: Answer.self) {
        guard $0.count >= 0 else { throw ValidationFailure.negativeCount }
    }
    #expect(decoded == expected)
    for invalid in ["```json\n{\"label\":\"packet\",\"count\":3}\n```", "{\"label\":\"packet\"}", "{\"label\":\"packet\",\"count\":"] {
        #expect(throws: IntelligenceError.self) { try StructuredOutput.decode(invalid, as: Answer.self) }
    }
    #expect(throws: IntelligenceError.self) {
        try StructuredOutput.decode("{\"label\":\"packet\",\"count\":-1}", as: Answer.self) {
            guard $0.count >= 0 else { throw ValidationFailure.negativeCount }
        }
    }
}

@Test func decodeThroughputExcludesFirstTokenLatencyAndSurvivesEmptyOutput() throws {
    let metrics = GenerationMetrics(promptTokens: 100, generatedTokens: 21, firstTokenSeconds: 2,
                                    generationSeconds: 4, decodeSeconds: 2, peakFootprintBytes: nil,
                                    mlxPeakAllocatedBytes: 1024, finishReason: .length)
    #expect(metrics.tokensPerSecond == 10)
    #expect(try JSONDecoder().decode(GenerationMetrics.self, from: JSONEncoder().encode(metrics)) == metrics)
    let empty = GenerationMetrics(promptTokens: 100, generatedTokens: 0, firstTokenSeconds: nil,
                                  generationSeconds: 1, decodeSeconds: 0, peakFootprintBytes: nil,
                                  mlxPeakAllocatedBytes: 1024, finishReason: .cancelled)
    #expect(empty.tokensPerSecond == 0)
}
