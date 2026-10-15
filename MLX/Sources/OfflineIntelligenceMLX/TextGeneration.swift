import Foundation
import MLX
import MLXLMCommon
import OfflineIntelligence

/// No MLXArray, cache, iterator, or ModelContext escapes this synchronous container-executor closure.
enum TextGeneration {
    static func run(context: ModelContext, model: ModelDescriptor, request: GenerationRequest,
                    cancellation: CancellationSignal,
                    continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) throws -> GenerationMetrics {
        let start = MemoryProbe.now
        let sampler = FootprintSampler()
        defer { MemoryProbe.synchronize() }
        Memory.peakMemory = 0
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": request.system],
            ["role": "user", "content": request.prompt],
        ]
        // Both models use their bundled chat template, with thinking explicitly disabled.
        let tokens = try context.tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
        try request.validateTokenCount(tokens.count, model: model)
        var firstAt: UInt64?, lastAt: UInt64?
        var generated = 0
        var generatedTokenIDs: [Int] = []
        var emittedText = ""
        var finish: GenerationFinishReason = .length
        var iterator: TokenIterator?
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var stopTokens = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stopTokens.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stopTokens.insert(id) }
        }
        // These are Qwen's turn and text terminators, including EOS entries omitted by some converted configs.
        for token in ["<|im_end|>", "<|endoftext|>"] {
            if let id = context.tokenizer.convertTokenToId(token) { stopTokens.insert(id) }
        }
        let prefill = PrefillParameters(stepSize: 128, chunking: .balanced, progress: { _, _ in
            if !MLXForegroundExecution.isAllowed { cancellation.cancel() }
            else if MemoryProbe.elapsed(since: start) >= request.timeoutSeconds { cancellation.stop(.timeout) }
        })
        let parameters = GenerateParameters(maxTokens: request.maxOutputTokens, maxKVSize: request.maxContextTokens,
                                            temperature: request.temperature, topP: request.topP,
                                            prefill: prefill, seed: request.seed)
        do {
            if !MLXForegroundExecution.isAllowed { cancellation.cancel() }
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens.map(Int32.init))),
                                         model: context.model, parameters: parameters)
            while generated < request.maxOutputTokens {
                if !MLXForegroundExecution.isAllowed { cancellation.cancel() }
                if let reason = cancellation.reason { finish = reason; break }
                if Task.isCancelled { finish = .cancelled; break }
                if MemoryProbe.elapsed(since: start) >= request.timeoutSeconds { finish = .timeout; break }
                guard let token = autoreleasepool(invoking: { iterator?.next() }) else { finish = .length; break }
                // The just-completed GPU step may have crossed the deadline or foreground boundary.
                if !MLXForegroundExecution.isAllowed { cancellation.cancel() }
                if let reason = cancellation.reason { finish = reason; break }
                if Task.isCancelled { finish = .cancelled; break }
                if MemoryProbe.elapsed(since: start) >= request.timeoutSeconds { finish = .timeout; break }
                if stopTokens.contains(token) { finish = .stop; break }
                let now = MemoryProbe.now
                if firstAt == nil { firstAt = now }
                lastAt = now
                generated += 1
                generatedTokenIDs.append(token)
                detokenizer.append(token: token)
                if let chunk = detokenizer.next(), !chunk.isEmpty {
                    emittedText += chunk
                    continuation.yield(.chunk(chunk))
                }
            }
        } catch is CancellationError {
            finish = cancellation.reason ?? .cancelled
        }
        // TokenIterator pipelines one token ahead. Drain CPU work and synchronize GPU only while foreground
        // execution is permitted; the GPU barrier itself commits a command buffer in the pinned backend.
        MemoryProbe.synchronize()
        iterator = nil
        // Flush a final incomplete byte sequence (or a literal replacement character withheld by the upstream
        // detokenizer) from the authoritative full decode. Compare scalars so joined emoji/accents stay intact.
        let finalText = context.tokenizer.decode(tokenIds: generatedTokenIDs, skipSpecialTokens: false)
        let scalars = finalText.unicodeScalars, emittedScalars = emittedText.unicodeScalars
        guard scalars.count >= emittedScalars.count,
              zip(scalars, emittedScalars).allSatisfy({ $0 == $1 }) else {
            throw IntelligenceError.invalidStructuredOutput("token decoder rewrote an already streamed prefix")
        }
        let tail = String(scalars.dropFirst(emittedScalars.count))
        if !tail.isEmpty { continuation.yield(.chunk(tail)) }
        let elapsed = MemoryProbe.elapsed(since: start)
        if !MLXForegroundExecution.isAllowed { cancellation.cancel() }
        if let reason = cancellation.reason { finish = reason }
        else if Task.isCancelled { finish = .cancelled }
        else if elapsed >= request.timeoutSeconds { finish = .timeout }
        let first = firstAt.map { Double($0 - start) / 1_000_000_000 }
        let decode: Double
        if let firstAt, let lastAt { decode = Double(lastAt - firstAt) / 1_000_000_000 } else { decode = 0 }
        return GenerationMetrics(promptTokens: tokens.count, generatedTokens: generated, firstTokenSeconds: first,
                                 generationSeconds: elapsed, decodeSeconds: decode, peakFootprintBytes: sampler.stop(),
                                 mlxPeakAllocatedBytes: Memory.peakMemory, finishReason: finish)
    }
}
