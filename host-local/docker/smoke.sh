#!/usr/bin/env bash
set -Eeuo pipefail

: "${DSH_PORT:=3080}"

deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' dsh-web 2>/dev/null || true)"
  if [[ "$state" == healthy ]]; then
    break
  fi
  if [[ "$state" == exited || "$state" == dead ]]; then
    docker logs --tail 200 dsh-web >&2 || true
    exit 1
  fi
  sleep 2
done

test "${state:-missing}" = healthy

test "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' bsk-daemon)" = healthy

code="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$DSH_PORT/")"
[[ "$code" == 200 || "$code" == 401 ]]

docker exec dsh-web bash -c \
  'test "$(id -u)" = 1000 && test "$(id -g)" = 1000 && command -v codex && command -v claude && command -v bsk'

docker exec dsh-web bash -c \
  'bsk status --json | jq -e '\''(.browsers | length) > 0 and .browsers[0].unresponsive == false'\'' >/dev/null'

docker exec bsk-daemon bash -c \
  'bsk status --json | jq -e '\''.ws_port == 52800 and (.browsers | length) > 0'\'' >/dev/null'

docker inspect --format '{{.HostConfig.NetworkMode}}' dsh-web | grep -qx host
docker exec dsh-web bash -c "ps -eo args | grep -v grep | grep -q -- '--no-open'"

printf 'DSH is healthy on http://127.0.0.1:%s (HTTP %s)\n' "$DSH_PORT" "$code"
