#!/usr/bin/env bash
set -Eeuo pipefail

# A manually started daemon may still own the shared socket/port on the first
# Compose handoff. Ask it to stop through the supported CLI instead of killing
# an unrelated process by name or PID.
if bsk status --json >/dev/null 2>&1; then
  bsk daemon stop --json >/dev/null
fi

deadline=$((SECONDS + 10))
while ss -ltn | grep -q '127.0.0.1:52800'; do
  if (( SECONDS >= deadline )); then
    printf 'BrowserSkill port 52800 did not become free during handoff\n' >&2
    exit 1
  fi
  sleep 0.2
done

exec bsk daemon start --foreground
