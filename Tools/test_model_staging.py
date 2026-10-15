#!/usr/bin/env python3
"""Exercise stale model recovery and source integrity without downloading or allocating a model."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
import build_hosts

class ModelStagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="offline-model-staging-")
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "source"
        self.target = Path(self.temp.name) / "target"
        self.source.mkdir(); self.target.mkdir()
        data = b"verified-checkpoint"
        self.expected = {"repositoryID": "fixture/model", "revision": "a" * 40,
                         "files": {"model.safetensors": {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}}
        (self.source / "model-metadata.json").write_text(json.dumps(self.expected))
        (self.source / "model.safetensors").write_bytes(data)

    def test_same_size_newer_corrupt_stage_is_repaired(self):
        build_hosts.stage_verified_model(self.source, self.target, self.expected)
        weight = self.target / "model.safetensors"
        weight.write_bytes(b"x" * self.expected["files"]["model.safetensors"]["size"])
        stamp = (self.source / "model.safetensors").stat().st_mtime + 1000
        os.utime(weight, (stamp, stamp))
        build_hosts.stage_verified_model(self.source, self.target, self.expected)
        self.assertEqual(weight.read_bytes(), (self.source / "model.safetensors").read_bytes())

    def test_stale_extra_weights_are_removed(self):
        (self.target / "old.safetensors").write_bytes(b"stale")
        build_hosts.stage_verified_model(self.source, self.target, self.expected)
        self.assertFalse((self.target / "old.safetensors").exists())
        build_hosts.verify_model(self.target, self.expected)

    def test_corrupt_source_is_rejected_without_altering_source(self):
        weight = self.source / "model.safetensors"
        bad = b"x" * weight.stat().st_size
        weight.write_bytes(bad)
        with self.assertRaises(RuntimeError):
            build_hosts.stage_verified_model(self.source, self.target, self.expected)
        self.assertEqual(weight.read_bytes(), bad)

if __name__ == "__main__":
    unittest.main()
