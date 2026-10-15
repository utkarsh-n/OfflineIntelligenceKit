#!/usr/bin/env python3
"""Prove canonical and staged source parity before an Xcode build."""
import hashlib
import json
from pathlib import Path
import sys

source, staged = map(Path, sys.argv[1:3])
entries = []
for path in sorted(source.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(source)
    if any(p in {".build", ".git", ".swiftpm", "__pycache__", "Documentation"} or p.endswith(".xcodeproj") for p in relative.parts):
        continue
    if relative.parts[:3] == ("BenchmarkApp", "Resources", "Models"):
        continue
    target = staged / relative
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"Source parity failed: {relative}")
    entries.append({"path": str(relative), "sha256": digest})
output = staged.parent / "source-parity.json"
output.write_text(json.dumps({"matched": len(entries), "files": entries}, indent=2) + "\n")
print(f"Canonical/staged source parity: {len(entries)} files")
