#!/usr/bin/env python3
"""Fetch immutable, verified Qwen checkpoints on the Mac. The app never downloads."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from datetime import datetime, timezone

MODELS = {
    "qwen-2b": ("mlx-community/Qwen3.5-2B-4bit", "674aaa7240b91e8012fcad5d791b7dfe5ba90207", "Qwen/Qwen3.5-2B", "15852e8c16360a2fea060d615a32b45270f8a8fc"),
    "qwen-4b": ("mlx-community/Qwen3.5-4B-4bit", "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c", "Qwen/Qwen3.5-4B", "851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a"),
}
REQUIRED = {"config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "model.safetensors", "model.safetensors.index.json"}
OPTIONAL = {"preprocessor_config.json", "processor_config.json", "video_preprocessor_config.json", "vocab.json"}

def curl(url, destination=None):
    args = ["curl", "--fail", "--location", "--retry", "3", "--retry-delay", "2", "--connect-timeout", "30"]
    if destination:
        args += ["--output", str(destination)]
    else:
        args += ["--silent", "--show-error"]
    return subprocess.run(args + [url], check=True, capture_output=not bool(destination)).stdout

def digests(path):
    size = path.stat().st_size
    sha = hashlib.sha256()
    git = hashlib.sha1(f"blob {size}\0".encode())
    with path.open("rb") as f:
        for b in iter(lambda: f.read(8 * 1024 * 1024), b""):
            sha.update(b)
            git.update(b)
    return sha.hexdigest(), git.hexdigest()

def verify(path, spec):
    if not path.is_file() or path.stat().st_size != spec["size"]:
        return None
    sha, git = digests(path)
    expected = spec.get("lfs", {}).get("sha256")
    if (expected and sha != expected) or (not expected and git != spec["blobId"]):
        return None
    return sha

def fetch_one(slug, info, root):
    repo, revision, base, base_revision = info
    directory = root / slug
    directory.mkdir(parents=True, exist_ok=True)
    api = json.loads(curl(f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true"))
    if api["sha"] != revision:
        raise RuntimeError("Snapshot revision mismatch")
    specs = {f["rfilename"]: f for f in api["siblings"]}
    if REQUIRED - specs.keys():
        raise RuntimeError(f"Missing model files: {REQUIRED - specs.keys()}")
    checksums = {}
    candidates = [Path.home() / "Developer/cipher-llm/models/Qwen3.5-4B-MLX-4bit"] if slug == "qwen-4b" else []
    for name in sorted(REQUIRED | (OPTIONAL & specs.keys())):
        spec = specs[name]
        target = directory / name
        checksum = verify(target, spec)
        if not checksum:
            for candidate in candidates:
                existing = candidate / name
                checksum = verify(existing, spec)
                if checksum:
                    # APFS cloning keeps large files outside the synced workspace.
                    subprocess.run(["cp", "-c", str(existing), str(target)], check=True)
                    break
        if not checksum:
            temporary = directory / (name + ".part")
            print(f"Downloading {slug}/{name} ({spec['size']:,} bytes)", flush=True)
            curl(f"https://huggingface.co/{repo}/resolve/{revision}/{name}", temporary)
            checksum = verify(temporary, spec)
            if not checksum:
                raise RuntimeError(f"Digest mismatch: {temporary}")
            os.replace(temporary, target)
        checksums[name] = {"sha256": checksum, "size": target.stat().st_size}
    license_path = directory / "LICENSE"
    curl(f"https://huggingface.co/{base}/resolve/{base_revision}/LICENSE", license_path)
    metadata = {
        "schemaVersion": 1, "repositoryID": repo, "revision": revision,
        "baseModel": base, "baseRevision": base_revision, "license": "Apache-2.0",
        "licenseSource": f"https://huggingface.co/{base}/blob/{base_revision}/LICENSE",
        "quantizationBits": 4, "files": checksums,
        "verifiedAt": datetime.now(timezone.utc).isoformat(),
        "runtime": {"mlx-swift": "0.32.3", "mlx-swift-lm": "3.32.3", "swift-transformers": "1.3.0"},
    }
    (directory / "model-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Verified {slug}: {revision}", flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path.home() / "Developer/offline-intelligence-models")
    parser.add_argument("--model", choices=list(MODELS), action="append")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    choices = args.model or list(MODELS)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(fetch_one, name, MODELS[name], args.directory) for name in choices]
        for future in futures:
            future.result()

if __name__ == "__main__":
    main()
