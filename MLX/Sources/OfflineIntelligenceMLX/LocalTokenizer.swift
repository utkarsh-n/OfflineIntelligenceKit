import Foundation
import MLXLMCommon
import Tokenizers

/// Local modelFolder is the only tokenizer entry point. MLXHuggingFace is deliberately not linked.
public struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    public init() {}
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return LocalTokenizerBridge(tokenizer)
    }
}

private struct LocalTokenizerBridge: MLXLMCommon.Tokenizer {
    let underlying: any Tokenizers.Tokenizer
    init(_ underlying: any Tokenizers.Tokenizer) { self.underlying = underlying }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { underlying.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { underlying.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { underlying.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { underlying.convertIdToToken(id) }
    var bosToken: String? { underlying.bosToken }
    var eosToken: String? { underlying.eosToken }
    var unknownToken: String? { underlying.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try underlying.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
