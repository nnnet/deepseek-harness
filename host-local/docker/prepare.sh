#!/usr/bin/env bash
set -Eeuo pipefail

: "${DSH_REPO_PATH:?DSH_REPO_PATH is required}"
: "${DSH_PROFILE_PATH:?DSH_PROFILE_PATH is required}"
export PNPM_CONFIG_STORE_DIR="${PNPM_CONFIG_STORE_DIR:-$DSH_HOME/.pnpm-store}"

cd "$DSH_REPO_PATH"

archive="$DSH_HOME/_archive/docker-preflight-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$archive"
for file in package.json pnpm-lock.yaml pnpm-workspace.yaml cordis.yml cordis.patch.yml; do
  if [[ -f "$DSH_PROFILE_PATH/$file" ]]; then
    cp -a "$DSH_PROFILE_PATH/$file" "$archive/$file"
  fi
done

pnpm install \
  --frozen-lockfile \
  --network-concurrency 4 \
  --fetch-retries 5 \
  --fetch-retry-mintimeout 20000 \
  --fetch-retry-maxtimeout 120000 \
  --fetch-timeout 300000

pnpm run build

pnpm --prefix "$DSH_PROFILE_PATH" install \
  --no-frozen-lockfile \
  --no-strict-peer-dependencies \
  --network-concurrency 4 \
  --fetch-retries 5 \
  --fetch-retry-mintimeout 20000 \
  --fetch-retry-maxtimeout 120000 \
  --fetch-timeout 300000

printf 'Profile metadata backup: %s\n' "$archive"
printf 'Prepared DSH source: %s\n' "$(node -p "require('./package.json').version")"
printf 'Codex: %s\n' "$(codex --version)"
printf 'Claude: %s\n' "$(claude --version)"
