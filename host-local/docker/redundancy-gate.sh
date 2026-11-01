#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

up_count="$(rg -n '\$\(COMPOSE\) up ' host-local/Makefile | wc -l)"
test "$up_count" -eq 1

if rg -n 'docker compose (run|up)|\$\(COMPOSE\) (run|up)' bdd; then
  printf 'BDD scenarios must not start Compose services themselves\n' >&2
  exit 1
fi

printf 'redundancy gate: one deploy up, no nested Compose launches in BDD\n'
