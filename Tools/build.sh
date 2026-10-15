#!/bin/zsh
# Stage source away from iCloud coordination. Model data stays outside the workspace.
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${OFFLINE_INTELLIGENCE_BUILD_ROOT:-$HOME/Developer/offline-intelligence-build}"
MODEL_ROOT="${OFFLINE_INTELLIGENCE_MODEL_ROOT:-$HOME/Developer/offline-intelligence-models}"
MODE="${1:-device}"
if [[ "$MODE" == sim ]] && rg -q '^Status: ACTIVE$' "$SOURCE_ROOT/Documentation/SIMULATOR_HOLD.md" 2>/dev/null; then
  print "Simulator work is held during Time Machine recovery; see Documentation/SIMULATOR_HOLD.md."
  exit 3
fi
if [[ "$MODE" == sim && -z "${OFFLINE_INTELLIGENCE_BUILD_ROOT:-}" ]]; then
  BUILD_ROOT="$HOME/Developer/offline-intelligence-simulator-build"
fi
STAGED_ROOT="$BUILD_ROOT/OfflineIntelligenceKit"
mkdir -p "$STAGED_ROOT"
rsync -a --delete --exclude '.build' --exclude '.git' --exclude '.swiftpm' --exclude '__pycache__' --exclude '*.xcodeproj' \
  --exclude 'BenchmarkApp/Resources/Models' "$SOURCE_ROOT/" "$STAGED_ROOT/"
mkdir -p "$STAGED_ROOT/BenchmarkApp/Resources/Models"
if [[ "$MODE" == device ]]; then
  for model in qwen-2b qwen-4b; do
    [[ -f "$MODEL_ROOT/$model/model-metadata.json" ]] || { print "Missing verified $model: run Tools/fetch_models.py"; exit 1; }
    mkdir -p "$STAGED_ROOT/BenchmarkApp/Resources/Models/$model"
    for file in "$MODEL_ROOT/$model/"*; do
      [[ "$file" == *.part ]] && continue
      destination="$STAGED_ROOT/BenchmarkApp/Resources/Models/$model/${file:t}"
      [[ -f "$destination" && $(stat -f %z "$file") == $(stat -f %z "$destination") && ! "$file" -nt "$destination" ]] || cp -c -p "$file" "$destination"
    done
  done
fi
# Verify all staged source files before trusting the resulting build.
python3 "$SOURCE_ROOT/Tools/verify_staging.py" "$SOURCE_ROOT" "$STAGED_ROOT"
cd "$STAGED_ROOT/BenchmarkApp"
xcodegen generate --quiet
if [[ "$MODE" == device ]]; then
  SIGNING_ARGUMENTS=(-allowProvisioningUpdates)
  if [[ "${OFFLINE_INTELLIGENCE_UNSIGNED:-0}" == 1 ]]; then
    SIGNING_ARGUMENTS=(CODE_SIGNING_ALLOWED=NO)
  fi
  xcodebuild -project OfflineIntelligenceBench.xcodeproj -scheme OfflineIntelligenceBench \
    -configuration Release -destination 'generic/platform=iOS' "${SIGNING_ARGUMENTS[@]}" \
    -derivedDataPath "${OFFLINE_INTELLIGENCE_DERIVED_DATA:-$BUILD_ROOT/DerivedData}" -skipPackagePluginValidation -skipMacroValidation build
elif [[ "$MODE" == sim ]]; then
  xcodebuild -project OfflineIntelligenceBench.xcodeproj -scheme OfflineIntelligenceBench \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${OFFLINE_INTELLIGENCE_DERIVED_DATA:-$BUILD_ROOT/SimulatorData}" -skipPackagePluginValidation -skipMacroValidation build
else
  print "Usage: Tools/build.sh device|sim"
  exit 2
fi
