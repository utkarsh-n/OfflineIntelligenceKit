#!/usr/bin/env python3
"""Stage integrated iPhone hosts with local verified models, then build generic physical-device Release apps."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil

KIT = Path(__file__).resolve().parents[1]
SOURCE = KIT.parent
HOSTS = {
    "Lilt": ("Lilt", "Lilt", "App/Resources/Models"),
    "AttentionMachine": ("AttentionMachine", "AttentionMachine", "Resources/Models"),
    "Loom": ("Loom", "Loom", "Loom/Resources/Models"),
    "Cipher": ("Cipher", "Cipher", "Cipher/Resources/Models"),
    "Boss Calendar": ("Boss Calendar", "BossCalendar", "App/Resources/Models"),
    "Scrolls": ("Scrolls/Native", "Scrolls", "Scrolls/Resources/Models"),
}

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

def mirror(source, destination, extra_excludes=()):
    destination.mkdir(parents=True, exist_ok=True)
    excludes = (".git", ".build", ".swiftpm", "DerivedData", "node_modules", "__pycache__", "*.xcodeproj", ".DS_Store", *extra_excludes)
    run(["rsync", "-a", "--delete", *[f"--exclude={x}" for x in excludes], f"{source}/", f"{destination}/"])

def clone_file(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and source.stat().st_size == destination.stat().st_size and source.stat().st_mtime_ns <= destination.stat().st_mtime_ns:
        return
    run(["cp", "-c", "-p", source, destination])

def clone_folder(source, destination, clean=False):
    if not source.is_dir():
        raise RuntimeError(f"Required local model/resource is missing: {source}")
    destination.mkdir(parents=True, exist_ok=True)
    if clean:
        for existing in destination.rglob("*"):
            if existing.is_file() and not (source / existing.relative_to(destination)).is_file():
                existing.unlink()
    for file in source.rglob("*"):
        if file.is_file() and not file.name.endswith(".part"):
            clone_file(file, destination / file.relative_to(source))

def verify_model(folder, expected):
    metadata = json.loads((folder / "model-metadata.json").read_text())
    if metadata["repositoryID"] != expected["repositoryID"] or metadata["revision"] != expected["revision"]:
        raise RuntimeError(f"Checkpoint provenance mismatch: {folder}")
    expected_weights = {name for name in expected["files"] if name.endswith(".safetensors")}
    if {p.name for p in folder.glob("*.safetensors")} != expected_weights:
        raise RuntimeError(f"Unexpected safetensors files: {folder}")
    for filename, record in expected["files"].items():
        file = folder / filename
        if not file.is_file() or file.stat().st_size != record["size"]:
            raise RuntimeError(f"Missing or incorrectly sized model file: {file}")
        digest = hashlib.sha256()
        with file.open("rb") as stream:
            for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != record["sha256"]:
            raise RuntimeError(f"Model integrity mismatch: {file}")
    return metadata

def stage_verified_model(source, destination, expected):
    clone_folder(source, destination, clean=True)
    try:
        verify_model(destination, expected)
    except RuntimeError:
        # Only the owned staged copy is repaired. Source model data is never modified.
        for filename in (*expected["files"], "model-metadata.json"):
            run(["cp", "-c", "-p", source / filename, destination / filename])
        verify_model(destination, expected)

def source_parity(source, staged, excluded_prefixes=()):
    entries = []
    for file in sorted(source.rglob("*")):
        if not file.is_file() or file.suffix not in (".swift", ".metal", ".h", ".yml"):
            continue
        rel = file.relative_to(source)
        if any(x in (".build", ".git", ".swiftpm", "DerivedData", "node_modules") or x.endswith(".xcodeproj") for x in rel.parts):
            continue
        if any(str(rel).startswith(prefix) for prefix in excluded_prefixes):
            continue
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        copy = staged / rel
        if not copy.is_file() or hashlib.sha256(copy.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Staged source does not match: {file}")
        entries.append({"path": str(rel), "sha256": digest})
    return entries

def stage_host(name, workspace, model_root, choices):
    relative, scheme, resources = HOSTS[name]
    app_source, app_stage = SOURCE / relative, workspace / relative
    if name == "Scrolls":
        mirror(SOURCE / "Scrolls", workspace / "Scrolls", ("data", "Native/Scrolls/Resources/Models", "Native/Scrolls/Resources/Bundled", "Native/Reports"))
        mirror(SOURCE / "LabKit", workspace / "LabKit")
        run(["zsh", app_stage / "Tools/gen-buildinfo.sh", workspace / "Scrolls", "full"])
        packs = Path.home() / "Developer/scrolls-packs/current"
        for file in ("starter.atlas", "cipher-meta.scrollspack", "cipher-text.scrollspack"):
            origin, target = packs / file, app_stage / "Scrolls/Resources/Bundled" / file
            if origin.is_dir(): clone_folder(origin, target)
            elif origin.is_file(): clone_file(origin, target)
        clone_folder(Path.home() / "Developer/scrolls-models/Qwen3-Embedding-0.6B-8bit", app_stage / resources / "Qwen3-Embedding-0.6B-8bit", clean=True)
        run([sys.executable, app_stage / "Tools/bundle-shared-models.py", "--destination", app_stage / resources,
             "--generation-root", model_root, "--models", "both" if "4b" in choices else "2b"])
    else:
        extra = [resources]
        if name == "AttentionMachine": extra += ["Resources/Model", "Runtime/models"]
        if name == "Loom": extra += ["Loom/Resources/Qwen"]
        mirror(app_source, app_stage, extra)
    if name == "AttentionMachine":
        clone_folder(app_source / "Resources/Model", app_stage / "Resources/Model")
    if name == "Loom":
        root = Path.home() / "Developer/loom-data/qwen"
        clone_folder(root / "Qwen3-4B-Instruct-2507-4bit", app_stage / "Loom/Resources/Qwen")
        clone_folder(root / "extras", app_stage / "Loom/Resources/Qwen")
    for choice in choices:
        destination = app_stage / resources / f"qwen-{choice}"
        expected = json.loads((KIT / f"Documentation/Models/qwen-{choice}-metadata.json").read_text())
        stage_verified_model(model_root / f"qwen-{choice}", destination, expected)
    if "4b" not in choices:
        optional = app_stage / resources / "qwen-4b"
        if optional.is_dir(): shutil.rmtree(optional)
    exclusions = ("ScrollsKit/Sources/ScrollsCore/Generated/BuildInfo.swift",) if name == "Scrolls" else ()
    parity = source_parity(app_source, app_stage, exclusions)
    run(["xcodegen", "generate", "--quiet"], cwd=app_stage)
    pins = app_stage / f"{scheme}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if not pins.is_file():
        pins.parent.mkdir(parents=True, exist_ok=True)
        clone_file(KIT / "Documentation/BenchmarkPackage.resolved", pins)
    return app_stage, scheme, parity

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", action="append", required=True, choices=HOSTS)
    parser.add_argument("--build-root", type=Path, default=Path.home() / "Developer/offline-app-integration")
    parser.add_argument("--model-root", type=Path, default=Path.home() / "Developer/offline-intelligence-models")
    parser.add_argument("--models", choices=("both", "2b"), default="both", help="2b creates a smaller build; 4B then needs a verified Documents/Models/qwen-4b import.")
    parser.add_argument("--stage-only", action="store_true")
    parser.add_argument("--unsigned", action="store_true")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    local_xcode = Path.home() / "Library/Developer/XcodeInstallations/27.2-beta-2/Xcode-beta.app/Contents/Developer"
    if "DEVELOPER_DIR" not in os.environ and local_xcode.is_dir():
        os.environ["DEVELOPER_DIR"] = str(local_xcode)
    workspace = args.build_root / "Workspace"
    if workspace.resolve().is_relative_to(SOURCE.resolve()):
        parser.error("Build staging must be outside the synced source workspace.")
    choices = ("2b", "4b") if args.models == "both" else ("2b",)
    for choice in choices:
        print(f"Verifying local Qwen {choice} snapshot", flush=True)
        verify_model(args.model_root / f"qwen-{choice}", json.loads((KIT / f"Documentation/Models/qwen-{choice}-metadata.json").read_text()))
    mirror(KIT, workspace / "OfflineIntelligenceKit", ("BenchmarkApp/Resources/Models",))
    kit_parity = source_parity(KIT, workspace / "OfflineIntelligenceKit")
    for name in args.app:
        print(f"Staging {name}", flush=True)
        app_stage, scheme, parity = stage_host(name, workspace, args.model_root, choices)
        record = {"recordedAt": datetime.now(timezone.utc).isoformat(), "app": name, "scheme": scheme,
                  "sourcePath": str(SOURCE / HOSTS[name][0]), "stagedPath": str(app_stage),
                  "models": list(choices), "hostSourceFiles": parity, "sharedSourceFiles": kit_parity,
                  "configuration": "Release", "destination": "generic/platform=iOS", "signed": not args.unsigned,
                  "buildSucceeded": False, "installed": False, "launched": False}
        evidence = args.build_root / "Evidence"; evidence.mkdir(parents=True, exist_ok=True)
        record_path = evidence / f"{scheme}.json"
        record_path.write_text(json.dumps(record, indent=2) + "\n")
        if args.stage_only:
            print(f"Staged {name}: {app_stage}", flush=True)
            continue
        log = evidence / f"{scheme}-build.log"
        derived = args.build_root / "DerivedData"
        command = ["xcodebuild", "-project", f"{scheme}.xcodeproj", "-scheme", scheme, "-configuration", "Release",
                   "-destination", "generic/platform=iOS", "-derivedDataPath", str(derived),
                   "-jobs", str(max(1,args.jobs)), "-skipPackagePluginValidation", "-skipMacroValidation"]
        command += ["CODE_SIGNING_ALLOWED=NO"] if args.unsigned else ["-allowProvisioningUpdates"]
        command += ["build"]
        record["command"] = command
        print(f"Building {name}; log: {log}", flush=True)
        with log.open("w") as stream:
            result = subprocess.run(command, cwd=app_stage, stdout=stream, stderr=subprocess.STDOUT)
        record["exitCode"] = result.returncode
        record["buildSucceeded"] = result.returncode == 0
        record["log"] = str(log)
        record["artifact"] = str(derived / f"Build/Products/Release-iphoneos/{scheme}.app")
        if result.returncode == 0 and not args.unsigned:
            signature = subprocess.run(["codesign", "--verify", "--deep", "--strict", record["artifact"]], capture_output=True, text=True)
            record["signatureVerified"] = signature.returncode == 0
            record["signatureDiagnostics"] = signature.stderr.strip()
        record_path.write_text(json.dumps(record, indent=2) + "\n")
        print(f"{name}: {'BUILD SUCCEEDED' if result.returncode == 0 else 'BUILD FAILED'}", flush=True)
        if result.returncode:
            print("\n".join(log.read_text(errors="replace").splitlines()[-60:]), flush=True)
            return result.returncode
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"build_hosts: {error}", file=sys.stderr)
        sys.exit(1)
