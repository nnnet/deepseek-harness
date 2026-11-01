#!/usr/bin/env bash
set -Eeuo pipefail

: "${DSH_REPO_PATH:?DSH_REPO_PATH is required}"
: "${DSH_PROFILE_PATH:?DSH_PROFILE_PATH is required}"
: "${DSH_PORT:=3080}"
export PNPM_CONFIG_STORE_DIR="${PNPM_CONFIG_STORE_DIR:-$DSH_HOME/.pnpm-store}"

cd "$DSH_REPO_PATH"

test -f apps/cli/lib/bin.js || {
  printf 'DSH is not built. Run: make -f host-local/Makefile docker-prepare\n' >&2
  exit 1
}

test -f "$DSH_PROFILE_PATH/package.json" || {
  printf 'DSH profile is missing: %s\n' "$DSH_PROFILE_PATH" >&2
  exit 1
}

export DSH_REPO="$DSH_REPO_PATH"

exec pnpm exec node --import tsx/esm apps/cli/src/bin.ts \
  --profile web \
  --no-open \
  --port "$DSH_PORT"
