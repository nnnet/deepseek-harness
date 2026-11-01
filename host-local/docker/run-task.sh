#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 ]]; then
  printf 'usage: %s TASK COMMAND [ARG...]\n' "$0" >&2
  exit 64
fi

task="$1"
shift
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
receipt_dir="$repo_root/host-local/state/docker/receipts"
log_dir="$repo_root/host-local/state/docker/logs"
run_id="$(date +%Y%m%d-%H%M%S)-$$"
log="$log_dir/$task-$run_id.log"
receipt="$receipt_dir/$task-$run_id.json"

mkdir -p "$log_dir" "$receipt_dir"
started_epoch="$(date +%s)"
started_at="$(date -Is)"

set +e
"$@" > >(tee "$log") 2>&1
exit_code=$?
set -e

finished_epoch="$(date +%s)"
finished_at="$(date -Is)"
duration=$((finished_epoch - started_epoch))

jq -n \
  --arg task "$task" \
  --arg startedAt "$started_at" \
  --arg finishedAt "$finished_at" \
  --arg log "$log" \
  --argjson durationSeconds "$duration" \
  --argjson exitCode "$exit_code" \
  '{task: $task, startedAt: $startedAt, finishedAt: $finishedAt,
    durationSeconds: $durationSeconds, exitCode: $exitCode, log: $log}' \
  > "$receipt"

printf 'receipt: %s\n' "$receipt"
exit "$exit_code"
