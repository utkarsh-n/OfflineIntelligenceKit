#!/usr/bin/env python3
"""Summarize a saved phone report without replacing failed or missing measurements."""
import argparse
import json
from pathlib import Path
import statistics

def median(values):
    return statistics.median(values) if values else None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    print(f"Device: {report['device']['deviceModel']} · OS {report['device']['osVersion']} · physical={report['device']['physicalDevice']}")
    print(f"Run: {report['id']} · {report['status']}")
    print("| Model | Finished trials | Objective passes | Load s | Median first token s | Median decode tok/s | Sampled peak GiB |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for model in report.get("modelRuns", []):
        trials = model.get("trials", [])
        metrics = [t['metrics'] for t in trials if t['status'] == 'completed' and t.get('metrics')]
        passed = sum(t.get('score', {}).get('disposition') == 'completed' and bool(t.get('score', {}).get('checks')) and
                     all(c['passed'] for c in t['score']['checks']) for t in trials)
        first = median([m['firstTokenSeconds'] for m in metrics if m.get('firstTokenSeconds') is not None])
        rate = median([max(0, m['generatedTokens'] - 1) / m['decodeSeconds'] if m['decodeSeconds'] > 0 else 0 for m in metrics])
        peaks = [t['metrics']['peakFootprintBytes'] for t in trials if t.get('metrics', {}).get('peakFootprintBytes') is not None]
        load = model.get('loadMetrics', {}).get('durationSeconds')
        fmt = lambda v: f"{v:.2f}" if v is not None else "unavailable"
        print(f"| {model['model']['displayName']} | {len(metrics)}/{len(trials)} | {passed}/{len(trials)} | {fmt(load)} | {fmt(first)} | {fmt(rate)} | {fmt(max(peaks)/2**30 if peaks else None)} |")
        thermal = sorted({obs['thermalState'] for t in trials for obs in [t.get('startObservation'), t.get('finishObservation')] if obs})
        print(f"\n{model['model']['displayName']}: thermal states {', '.join(thermal) or 'unavailable'}; load error {model.get('loadError') or 'none'}.\n")
        for t in trials:
            if t['status'] != 'completed' or t.get('score') and not all(c['passed'] for c in t['score']['checks']):
                failed = [c['name'] for c in t.get('score', {}).get('checks', []) if not c['passed']]
                print(f"- {t['fixtureID']} repeat {t.get('repeatIndex')}: {t['status']}; failed checks {failed}; error {t.get('error') or 'none'}")

if __name__ == '__main__':
    main()
