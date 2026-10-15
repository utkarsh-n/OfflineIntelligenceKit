# Shared offline intelligence in existing iPhone apps

October 14, 2026. The six existing apps with language-model assistance now share the same offline generation layer. `OfflineModelChoice` defaults to **Qwen3.5 2B, 4-bit** and persists an explicit optional **4B** selection separately in each app. Changing the choice releases the previous generation model before the next one loads.

| App | Shared generation feature | Model choice | Domain behavior preserved |
| --- | --- | --- | --- |
| Cipher | Lyric drafts, punch-ups, forged bars and verse continuation | Assist and On-device model settings | Rhyme/script verdicts and draft ranking; explicit optional Claude writer |
| Scrolls | Grounded grouping labels and glosses | Qwen screen | Embedding math, label/citation/grounding validation and exact model provenance |
| AttentionMachine | Paper teaching assistant, default local-model mode | Text assistant controls | Untrained paper machine and real Qwen3 Q/K attention trace remain separate |
| Loom | Grounded explanations of the current instrument | Ask offline sheet | Instrumented Qwen3 layers, interventions and same-checkpoint comparisons |
| Lilt | Description-to-maze recipe | Settings | Explicit counts/preferences, checked geometry, tilt physics and local parser fallback |
| Boss Calendar | Idea-to-build-phase proposals | Settings and idea shaping panel | Typed phase bounds, templates, saved-plan compatibility and scheduling authority |

## Shared contracts

- Root package: runtime-independent requests, model catalog, typed decoding, model choices, local directory resolution and complete-response transactions.
- MLX package: local loading, streaming, cancellation, memory metrics, process-wide residency lease and foreground execution gate. No automatic download or cloud fallback was added.
- Hosts cancel owning tasks on interruption and release resident models under memory pressure. The foreground gate denies new GPU work after UIKit's inactive notification; cleanup avoids a GPU synchronization barrier that would itself submit a Metal command buffer. An already-running upstream operation still ends cooperatively.
- Specialist attention engines and Scrolls embeddings acquire the shared external lease. They are drained/unloaded before ordinary generation becomes resident. Their numerical models were retained.
- Structured results pass the app's domain validator. Lilt additionally enforces the player's explicit quantities and preferences after model interpretation. Cipher discards truncated bars instead of presenting them as complete suggestions.

## Local models and builds

The canonical source workspace contains code and small provenance files. Verified model binaries stay under `~/Developer/offline-intelligence-models`; the helper clones them into `~/Developer/offline-app-integration/Workspace` and builds there. Scrolls also bundles its existing verified Qwen3 embedding model. AttentionMachine and Loom retain their existing Qwen3 tracing checkpoint.

```sh
cd '/path/to/developer/Documents/AI Stuff/OfflineIntelligenceKit'
python3 Tools/build_hosts.py --app Cipher --app Scrolls --app AttentionMachine --app Loom --app Lilt --app 'Boss Calendar'
```

Use `--stage-only` to prepare source/resources without compiling, `--unsigned` for an unsigned compile, or `--models 2b` for a smaller bundle. The optional 4B can then be supplied as a verified local folder in that app's Documents/Models. Each app has its own sandbox and preferences; this is shared code, rather than one cross-app model process or storage container. Bundling both generation checkpoints costs about 4.8 GB per app, plus any specialist resources.

Source parity records, dependency locks, build logs and signed artifacts are kept under the helper's `Evidence` and `DerivedData` folders. [IntegrationVerification.json](IntegrationVerification.json) records the final outcomes separately from [the earlier physical layer benchmark](BenchmarkResults.md).

## Verification boundaries

All six Release builds for generic iOS devices pass, with deep, strict signature verification. The final evidence collector matched every recorded Swift, Metal, C-header and YAML source against both the canonical workspace and the compiled staging folders, and checked the complete source inventories. The manifest retains dependency locks, signed artifact identities, bundled model provenance and build logs.

The shared suite passes **35 tests** (17 XCTest and 18 Swift Testing), including complete-response integrity, cancellation across load/generate/cleanup boundaries and concurrent-unload admission. Three small-file staging tests verify corruption repair, rejection of corrupt sources and removal of stale weights. Lilt passes 41 core/persistence tests, including the new typed recipe checks; Scrolls passes 32 pure domain/bridge tests; AttentionCore's 22 math tests pass; Boss's 24 new schema/provider checks pass.

Boss's portable scheduler harness also reproduces two existing idempotence failures (`fuzz217`, `fuzz330`) on unchanged planner code. The integration introduces no additional failures in that harness. Its [separate report](../../Boss%20Calendar/Documentation/OFFLINE_INTELLIGENCE.md) retains the baseline and integrated counts. A pre-existing optional nudge-to-idea reference was unwrapped to make its native notification target compile; standalone nudges still work.

Native build/signature outcomes are recorded in the JSON manifest. This integration pass does not claim new phone installation, onscreen interaction coverage or sustained hardware stability. The shared backend's earlier 2B/4B benchmark was completed on the physical iPhone; the new host wrappers have separate build and domain-test evidence. Simulator work remains held by [the recovery instruction](SIMULATOR_HOLD.md). AttentionMachine's previously deferred audio and 20-minute stability checks remain deferred.
