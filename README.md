# Offline Intelligence Kit

Reusable, offline text inference for our native iPhone apps. The public API and benchmark scoring have no MLX dependency; a separate Swift package supplies the real GPU backend. Hosts provide a verified local model directory. Generation never downloads a model or falls back to a cloud service.

## Packages

| Product | Location | Purpose |
| --- | --- | --- |
| `OfflineIntelligence` | Root package | Sendable model catalog, requests, streaming events, metrics, runtime protocol, and typed JSON validation |
| `OfflineIntelligenceBenchmarks` | Root package | Objective fixture scoring, reproducible plans, checkpointed evidence reports, and a runtime-independent runner |
| `OfflineIntelligenceMLX` | `MLX/` package | MLX loading, tokenizer bridge, generation, cancellation, unload, and memory sampling |
| Offline Intelligence app | `BenchmarkApp/` | Physical-device benchmark client and JSON export |

Minimum library platforms: iOS 17 and macOS 14. Swift tools version 6.4. The benchmark app targets iOS 27 and follows Metro Station's stable readouts and control layout.

Dependencies are pinned: MLX Swift 0.32.3, MLX Swift LM 3.32.3, swift-transformers 1.3.0, and swift-collections 1.5.0. The runtime does not link MLXHuggingFace or use a remote downloader. The first version supports text requests, without chat-history caching, image input, embeddings, or unrestricted tool execution.

## Use in another iPhone app

Add both local packages in Xcode: `OfflineIntelligenceKit` and `OfflineIntelligenceKit/MLX`. Link the products `OfflineIntelligence` and `OfflineIntelligenceMLX` to the host target. Keep a single runtime owned by an app service rather than recreate it from a view body. The benchmark project's `project.yml` is a complete example of these two package references.

```swift
import OfflineIntelligence
import OfflineIntelligenceMLX

let runtime = MLXIntelligenceRuntime()
let model = ModelCatalog.qwen2B
let directory = Bundle.main.resourceURL!
    .appendingPathComponent("Models/qwen-2b", isDirectory: true)
let load = try await runtime.load(model: model, directory: directory)
let stream = try await runtime.generate(GenerationRequest(
    prompt: "Explain this modeled circuit using the supplied values: ...",
    maxOutputTokens: 128))
for try await event in stream {
    switch event {
    case .chunk(let text):
        // Append the delta to the host's presentation state on MainActor.
        print(text, terminator: "")
    case .completed(let metrics):
        print(metrics.finishReason, metrics.firstTokenSeconds as Any)
    }
}
await runtime.unload()
```

The host owns content provenance, domain validation, lifecycle, and any action following generated text. A valid JSON shape alone does not establish factual correctness or authorize an action. Typed decoding remains a separate explicit step. Limits apply to rendered prompt tokens and the requested output/context budget. Concurrent requests are rejected rather than secretly queued.

Cancel on backgrounding or a memory warning. Wait for `cancel()` or `unload()` to return before switching models. Cancellation cooperates with prefill/decode work; it cannot preempt an in-flight GPU command instantly. Each completion records stop, token limit, cancellation, or timeout distinctly.

MLX cache settings and allocation counters are process-global. This package permits one resident runtime instance at a time. Hosts using other independent MLX engines must coordinate their tensor work and memory settings as well; the package's lease cannot serialize external engines.

## Prepare and run

```sh
python3 Tools/fetch_models.py
zsh Tools/build.sh device
```

The Mac-only preparation script downloads immutable snapshots, verifies Hugging Face LFS SHA-256 or Git blob IDs, and records provenance. Model binaries remain under `~/Developer/offline-intelligence-models`, outside the synced source workspace. The build script stages identical source under `~/Developer/offline-intelligence-build`, clones model files into its resources, and verifies source parity before building.

The benchmark app bundles both models. It requests Apple's increased-memory-limit entitlement; another host must assess its own memory budget and provisioning needs. Smaller requests reduce transient allocations but do not eliminate model-weight residency.

On this Mac, the default Xcode 27.0 tools reported no account for the new app, while the installed Xcode 27.2 beta 2 successfully provisioned it. The signed device build used this per-command selection, without changing the system-wide toolchain:

```sh
DEVELOPER_DIR="$HOME/Library/Developer/XcodeInstallations/27.2-beta-2/Xcode-beta.app/Contents/Developer" zsh Tools/build.sh device
```

Install the signed app on the connected phone, then launch with `--benchmark` to run both models. `--model 2b` or `--model 4b` selects one. Results checkpoint atomically under `Documents/BenchmarkReports/latest.json` and a run-specific file. A previous running checkpoint is displayed as interrupted on the next launch. The simulator displays the interface but does not run MLX inference.

## Benchmark method

Six fixtures cover instrument settings, a packet event, supplied circuit equations, a grounded packet explanation, mechanically constrained rewriting, and Spanish extraction. Each model has one excluded warmup and three measured repetitions per fixture. Both use the same prompt, token caps, seed, temperature zero, and top-p one. Thinking is disabled for these bounded completion tasks.

Reports retain prompts, complete outputs, objective checks, failures, model revisions, run order, timings, memory, and device conditions. First-token latency includes prompt preparation and prefill. Decode throughput excludes the first token. Process footprint and MLX allocator usage are different measurements; sampled peak footprint can miss brief spikes. Load timing is measured before the warmup and does not imply a cold operating-system file cache. Scores describe these fixtures' mechanical requirements, without a subjective creativity or general-intelligence rating.

Model order and thermal state affect comparisons. Start each performance run with the phone idle, Low Power Mode off, and thermal state nominal. A result with changed conditions remains useful evidence but should carry those conditions. Building, installing, launching, and completing a benchmark are separate verification outcomes.

Both models completed 18 measured trials on the iPhone 15 Pro Max. See [physical benchmark results](Documentation/BenchmarkResults.md) for the raw evidence and conditions. In this six-task suite, 2B passed all structured JSON tasks with lower observed latency and memory use; 4B also met every prose constraint. Start with 2B for these bounded app tasks and offer 4B where the additional memory fits. The phone's warmer thermal state during 4B testing prevents a controlled speed comparison.

## Existing app integrations

Cipher, Scrolls, AttentionMachine, Loom, Lilt and Boss Calendar now use the common catalog, local files and persisted `OfflineModelChoice`: 2B by default, 4B only when selected. [Integration details and validation](Documentation/AppIntegrations.md) record each app's entry point and the specialist engines retained for embeddings or measured attention.

`TextGenerationSession` supplies a complete-response transaction over any `IntelligenceRuntime`; the MLX product exposes `OfflineTextService.shared`. It rejects truncated, timed-out or cancelled results before domain code can accept them. Streaming hosts can use the runtime directly and display partial-result status. `MLXExternalModelLease` coordinates specialist MLX tensor residency; `MLXForegroundExecution` gates new work and GPU barriers during iOS lifecycle transitions. Cancellation remains cooperative at upstream compute/loading boundaries.

Build updated hosts outside the synced workspace, using the per-command Xcode toolchain selected by the helper:

```sh
python3 Tools/build_hosts.py --app Cipher --app Scrolls --app AttentionMachine --app Loom --app Lilt --app 'Boss Calendar'
```

The helper verifies source and staged checkpoint hashes, removes stale staged weights, clones local models, checks source parity, and signs Release builds for generic physical iOS devices. Both bundled generation models occupy about 4.8 GB per app. `--models 2b` creates a smaller build; selecting 4B then requires its verified local `Documents/Models/qwen-4b` folder. These apps have independent iOS sandboxes; model files and saved preferences are per app. Model preparation is a Mac operation, and generation has no downloader or cloud fallback.

## Checks

Simulator activity is currently held during Time Machine recovery. Follow `Documentation/SIMULATOR_HOLD.md`; use only the pure tests and physical-device workflow until the recovery chat releases the hold.

```sh
swift test --scratch-path /tmp/offline-intelligence-core-tests
```

After the recovery hold is released, `zsh Tools/build.sh sim` can compile the interface for simulator inspection.

Pure tests exercise budget boundaries, structured validation, strict fixture scoring, summary statistics, and runner behavior using controlled runtime doubles. Device reports establish real inference behavior. Neither simulated GPU results nor old results from another app are substituted for those reports.

## Model provenance and licenses

| Model | Quantized repository | Pinned revision |
| --- | --- | --- |
| Qwen3.5 2B 4-bit | `mlx-community/Qwen3.5-2B-4bit` | `674aaa7240b91e8012fcad5d791b7dfe5ba90207` |
| Qwen3.5 4B 4-bit | `mlx-community/Qwen3.5-4B-4bit` | `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c` |

Original [Qwen3.5 2B](https://huggingface.co/Qwen/Qwen3.5-2B) and [4B](https://huggingface.co/Qwen/Qwen3.5-4B) model licenses are Apache-2.0. The 4B community snapshot lacks license metadata, so preparation retains the original model's license and source revision explicitly. [MLX Swift](https://github.com/ml-explore/mlx-swift) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) use MIT; swift-collections and swift-transformers use Apache-2.0. Retain upstream notices when distributing a host app.


## Public snapshot

See [PUBLICATION.md](PUBLICATION.md) for publication exclusions and setup requirements.
