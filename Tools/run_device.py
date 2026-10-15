#!/usr/bin/env python3
"""Install/launch the benchmark and retain actual phone checkpoints on the Mac."""
import argparse
import json
from pathlib import Path
import subprocess
import time

BUNDLE = "com.utkarsh.offlineintelligencebench"

def command(args, check=True):
    return subprocess.run(["xcrun", "devicectl"] + args, check=check, capture_output=True, text=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--model", choices=["2b", "4b"])
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "Documentation/DeviceRuns")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if args.app:
        result = command(["device", "install", "app", "--device", args.device, str(args.app), "--json-output", str(args.output / "install.json")])
        print(result.stdout, flush=True)
    previous_id = None
    previous = args.output / "previous.json"
    copied = command(["device", "copy", "from", "--device", args.device, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                      "--source", "Documents/BenchmarkReports/latest.json", "--destination", str(previous), "--timeout", "20"], check=False)
    if copied.returncode == 0:
        previous_id = json.loads(previous.read_text()).get("id")
    launch = ["device", "process", "launch", "--device", args.device, "--terminate-existing", "--json-output", str(args.output / "launch.json"), BUNDLE, "--", "--benchmark"]
    if args.model:
        launch += ["--model", args.model]
    print(command(launch).stdout, flush=True)
    started = time.monotonic()
    watched_id = None
    local = args.output / "latest.json"
    while time.monotonic() - started < args.timeout:
        result = command(["device", "copy", "from", "--device", args.device, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                          "--source", "Documents/BenchmarkReports/latest.json", "--destination", str(local), "--timeout", "20"], check=False)
        if result.returncode == 0 and local.is_file():
            report = json.loads(local.read_text())
            # Never mistake a previous run's file for completion of this launch.
            if report.get("id") == previous_id:
                print("Waiting for the new run to create its checkpoint", flush=True)
                time.sleep(10)
                continue
            snapshot = args.output / f"{report['id']}.json"
            snapshot.write_bytes(local.read_bytes())
            if watched_id is None:
                watched_id = report['id']
            elif report['id'] != watched_id:
                print("Another run replaced the watched run. Its last checkpoint was preserved; completion is not inferred.", flush=True)
                return 3
            status = report.get("status")
            completed = sum(sum(t.get("status") != "running" for t in m.get("trials", [])) for m in report.get("modelRuns", []))
            print(f"Phone checkpoint {report.get('id')}: {status}, {completed} measured trials", flush=True)
            if status != "running":
                print(f"Saved physical-device result: {snapshot}", flush=True)
                return 0 if status == "completed" else 1
        else:
            print("Waiting for phone checkpoint", flush=True)
        time.sleep(10)
    print("Timed out; retained the latest actual checkpoint. This is not a completed benchmark.", flush=True)
    return 2

if __name__ == "__main__":
    raise SystemExit(main())
