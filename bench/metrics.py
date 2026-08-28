#!/usr/bin/env python3
"""Extract benchmark metrics from a dsh session log.

Usage:
  python3 bench/metrics.py <session-dir-or-session.jsonl[.zstd]> [--header]

Prints one tab-separated line: wall steps in_med in_max think_ratio tool_err compactions
"""
import argparse
import json
import statistics
import subprocess
from pathlib import Path

FIELDS = ["wall", "steps", "in_med", "in_max", "think_ratio", "tool_err", "compactions"]


def resolve_log_path(target: Path) -> Path:
    if target.is_dir():
        candidates = sorted(target.glob("session-*/session.jsonl.zstd")) or sorted(
            target.glob("session.jsonl.zstd")
        )
        if not candidates:
            raise SystemExit(f"no session.jsonl.zstd found under {target}")
        return candidates[-1]
    return target


def read_events(path: Path):
    if path.suffix == ".zstd":
        raw = subprocess.run(["zstd", "-dc", str(path)], check=True, capture_output=True).stdout.decode("utf-8")
    else:
        raw = path.read_text(encoding="utf-8")
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        yield json.loads(line)


def extract_metrics(events) -> dict:
    turn_starts = []
    turn_ends = []
    input_tokens = []
    reasoning_chunks = 0
    text_chunks = 0
    tool_err = 0
    steps = 0
    compactions = 0

    for event in events:
        etype = event.get("type")
        data = event.get("data") or {}
        if etype == "turn/start":
            turn_starts.append(event["time"])
        elif etype == "turn/end":
            turn_ends.append(event["time"])
        elif etype == "step/start":
            steps += 1
        elif etype == "compaction/start":
            compactions += 1
        elif etype == "reasoning-chunks":
            reasoning_chunks += 1
        elif etype == "text-chunks":
            text_chunks += 1
        elif etype == "assistant/chunk":
            chunk = data.get("chunk") or {}
            if chunk.get("type") == "usage":
                input_tokens.append(chunk["usage"]["inputTokens"])
        elif etype == "tool/result":
            message = data.get("message") or {}
            for block in message.get("content", []):
                if block.get("type") == "tool-result" and block.get("isError"):
                    tool_err += 1

    # session/end-seed and the config events that precede it (permission/preset,
    # sandbox/mode, approval/policy) carry the ORIGINAL session-creation timestamp,
    # which can be days older than the actual work if the session was reused/resumed.
    # turn/start..turn/end is the only reliable wall-clock boundary.
    if not turn_starts or not turn_ends:
        raise SystemExit("no turn/start or turn/end events found — not a completed task run")
    if not input_tokens:
        raise SystemExit("no usage chunks found — cannot compute in_med/in_max")

    wall = round((max(turn_ends) - min(turn_starts)) / 1000.0, 1)
    denom = reasoning_chunks + text_chunks
    think_ratio = round(reasoning_chunks / denom, 4) if denom else 0.0

    return {
        "wall": wall,
        "steps": steps,
        "in_med": statistics.median(input_tokens),
        "in_max": max(input_tokens),
        "think_ratio": think_ratio,
        "tool_err": tool_err,
        "compactions": compactions,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path, help="session directory, or path to session.jsonl(.zstd)")
    parser.add_argument("--header", action="store_true", help="print a TSV header line first")
    args = parser.parse_args()

    log_path = resolve_log_path(args.target)
    metrics = extract_metrics(read_events(log_path))

    if args.header:
        print("\t".join(FIELDS))
    print("\t".join(str(metrics[f]) for f in FIELDS))


if __name__ == "__main__":
    main()
