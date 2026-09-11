#!/usr/bin/env bash
#
# start-web.sh — локальный запуск dsh web с этого хоста и управляемый
# переезд на новые релизы.
#
# Живём всегда в одной ветке (HOST_BRANCH). Релизы апстрима приезжают
# внутрь неё слиянием тега — ветка не меняется, профиль не меняется,
# host-local/ переживает любой апгрейд.
#
# Команды:
#   start-web.sh              запустить web (по умолчанию)
#   start-web.sh check        только проверить новые релизы, ничего не менять
#   start-web.sh upgrade TAG  влить релизный тег в текущую ветку
#   start-web.sh status       где мы сейчас
#
set -euo pipefail

# ── конфигурация ──────────────────────────────────────────────────────
# Ветка, в которой живёт этот хост. Имя НЕ содержит версию — в этом весь
# смысл: при апгрейде меняется содержимое, не идентичность.
HOST_BRANCH="${DSH_HOST_BRANCH:-host/uadmin-raider18}"

# Профиль dsh. Тоже намеренно отвязан от версии: профиль — это 700+ МБ
# накопленных плагинов, его нельзя пересоздавать на каждый релиз.
PROFILE="${DSH_HOST_PROFILE:-web-pin-dsh-v0.1.2-rc.1}"

# Откуда берём релизы и как они называются.
UPSTREAM_REMOTE="${DSH_UPSTREAM_REMOTE:-origin}"
FORK_REMOTE="${DSH_FORK_REMOTE:-fork}"
RELEASE_TAG_GLOB="${DSH_RELEASE_TAG_GLOB:-dsh-v*}"

WEB_PORT="${DSH_WEB_PORT:-3000}"

# ── пути ──────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST_DIR="$REPO_ROOT/host-local"
STATE_DIR="$HOST_DIR/state"
CURRENT_RELEASE_FILE="$STATE_DIR/current-release"
SEEN_TAGS_FILE="$STATE_DIR/seen-tags"
RELEASE_LOG="$HOST_DIR/docs/release-log.md"

cd "$REPO_ROOT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

# Git с настроенной сортировкой предрелизов: без этого versionsort ставит
# dsh-v0.1.5-rc.1 ВЫШЕ dsh-v0.1.5, и "последний тег" оказывается неверным.
git_v() {
  git -c versionsort.suffix=-alpha \
      -c versionsort.suffix=-beta \
      -c versionsort.suffix=-rc \
      "$@"
}

# ── проверки ──────────────────────────────────────────────────────────

# Жить и запускаться только внутри своей ветки. Запуск с чужой ветки
# молча собрал бы не тот код в тот же профиль.
assert_host_branch() {
  local current
  current="$(git rev-parse --abbrev-ref HEAD)"
  [ "$current" = "$HOST_BRANCH" ] || die \
    "сейчас ветка '$current', а жить надо в '$HOST_BRANCH'. Переключись: git switch $HOST_BRANCH"
}

# Слияние в грязное дерево оставляет полурешённое состояние, из которого
# трудно выбраться. Для start это предупреждение, для upgrade — стоп.
worktree_is_dirty() {
  [ -n "$(git status --porcelain --untracked-files=no)" ]
}

# ── релизы ────────────────────────────────────────────────────────────

current_release() {
  if [ -s "$CURRENT_RELEASE_FILE" ]; then
    cat "$CURRENT_RELEASE_FILE"
  else
    # Ещё ни разу не апгрейдились этим скриптом — спрашиваем сам git,
    # какой релизный тег является предком HEAD.
    git_v describe --tags --abbrev=0 --match "$RELEASE_TAG_GLOB" 2>/dev/null || echo "unknown"
  fi
}

# Все релизные теги новее текущего. Новизна считается по достижимости, не
# по имени: тег, уже влитый в ветку, новым не является, как бы он ни
# назывался.
newer_releases() {
  local tag
  git_v tag --list "$RELEASE_TAG_GLOB" --sort=v:refname | while read -r tag; do
    [ -n "$tag" ] || continue
    if ! git merge-base --is-ancestor "$tag" HEAD 2>/dev/null; then
      echo "$tag"
    fi
  done
}

# Фиксация факта появления релиза. Отдельно от факта переезда: увидеть
# релиз и переехать на него — разные события, и лог должен их различать.
record_seen() {
  local tag="$1"
  mkdir -p "$STATE_DIR"
  touch "$SEEN_TAGS_FILE"
  # Строки файла — "дата<TAB>тег", поэтому сравниваем именно второе поле.
  cut -f2 "$SEEN_TAGS_FILE" | grep -qxF "$tag" && return 0
  printf '%s\t%s\n' "$(date -Is)" "$tag" >> "$SEEN_TAGS_FILE"
  return 1  # был новым
}

append_release_log() {
  local kind="$1" tag="$2" note="${3:-}"
  mkdir -p "$(dirname "$RELEASE_LOG")"
  [ -f "$RELEASE_LOG" ] || cat > "$RELEASE_LOG" <<'HEADER'
# Журнал релизов этого хоста

Пишется скриптом `host-local/scripts/start-web.sh`. Строка «замечен» —
релиз появился в апстриме; строка «переезд» — мы на него перешли.

| дата | событие | тег | заметка |
|---|---|---|---|
HEADER
  printf '| %s | %s | `%s` | %s |\n' "$(date -Is)" "$kind" "$tag" "$note" >> "$RELEASE_LOG"
}

# ── команды ───────────────────────────────────────────────────────────

cmd_fetch() {
  log "git fetch $UPSTREAM_REMOTE (теги релизов)"
  git fetch --tags --prune "$UPSTREAM_REMOTE"
  if git remote | grep -qx "$FORK_REMOTE"; then
    log "git fetch $FORK_REMOTE"
    git fetch --prune "$FORK_REMOTE" || warn "fetch $FORK_REMOTE не удался, продолжаю"
  fi
}

# git pull только если у ветки есть upstream: у чисто локальной ветки
# pull падает, и это не повод прерывать запуск.
cmd_pull() {
  if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    log "git pull --ff-only"
    git pull --ff-only || warn "pull не прошёл fast-forward, ветка расходится с upstream"
  else
    log "у $HOST_BRANCH нет upstream — pull пропущен (ветка локальная)"
  fi
}

cmd_check() {
  local cur new_count=0 fresh=()
  cur="$(current_release)"
  log "текущий релиз: $cur"

  while read -r tag; do
    [ -n "$tag" ] || continue
    new_count=$((new_count + 1))
    if ! record_seen "$tag"; then
      fresh+=("$tag")
      append_release_log "замечен" "$tag" ""
    fi
  done < <(newer_releases)

  if [ "$new_count" -eq 0 ]; then
    log "новых релизов нет"
    return 0
  fi

  warn "доступно новых релизов: $new_count"
  newer_releases | sed 's/^/      /'
  if [ "${#fresh[@]}" -gt 0 ]; then
    warn "впервые вижу: ${fresh[*]} (записано в host-local/docs/release-log.md)"
  fi
  printf '      переезд:  %s upgrade <тег>\n' "$0"
}

cmd_upgrade() {
  local tag="${1:-}"
  [ -n "$tag" ] || die "нужен тег: $0 upgrade dsh-v0.1.5-rc.2"
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
    || die "тега '$tag' нет локально — сделай '$0 check'"

  assert_host_branch
  worktree_is_dirty && die "рабочее дерево грязное — закоммить или спрячь перед переездом"

  # Точка возврата: слияние релиза затрагивает тысячи файлов, откат
  # через reflog возможен, но именованная ветка надёжнее.
  local safety="backup/${HOST_BRANCH##*/}-$(date +%Y%m%d-%H%M%S)"
  git branch "$safety"
  log "точка возврата: $safety"

  log "сливаю $tag в $HOST_BRANCH"
  if ! git merge --no-edit "$tag"; then
    warn "конфликты слияния. Разреши их и закоммить, либо откатись:"
    printf '      git merge --abort && git reset --hard %s\n' "$safety"
    exit 1
  fi

  mkdir -p "$STATE_DIR"
  echo "$tag" > "$CURRENT_RELEASE_FILE"
  append_release_log "переезд" "$tag" "откат: \`$safety\`"

  log "ставлю зависимости"
  pnpm install

  log "собираю"
  pnpm run build

  log "переехали на $tag. Профиль '$PROFILE' не тронут."
  printf '      откат при проблемах: git reset --hard %s\n' "$safety"
}

cmd_status() {
  printf 'ветка:    %s\n' "$(git rev-parse --abbrev-ref HEAD)"
  printf 'релиз:    %s\n' "$(current_release)"
  printf 'профиль:  %s\n' "$PROFILE"
  printf 'дерево:   %s\n' "$(worktree_is_dirty && echo 'грязное' || echo 'чистое')"
  local pending
  pending="$(newer_releases | tr '\n' ' ')"
  printf 'новее:    %s\n' "${pending:-нет}"
}

cmd_start() {
  assert_host_branch
  worktree_is_dirty && warn "рабочее дерево грязное — запускаю как есть"

  cmd_fetch
  cmd_pull
  cmd_check || true

  log "dsh --profile $PROFILE --port $WEB_PORT"
  # Именно '--profile <имя>', а НЕ подкоманда 'dsh web': 'web' — это алиас
  # для '--profile web', то есть базового профиля. Он бы поднялся пустым,
  # без единого плагина отсюда.
  #
  # URL с разовым токеном печатает сам dsh; скрипт его не перехватывает,
  # чтобы токен не оседал в логах.
  exec pnpm exec tsx apps/cli/src/bin.ts --profile "$PROFILE" --port "$WEB_PORT"
}

case "${1:-start}" in
  start)   cmd_start ;;
  check)   assert_host_branch; cmd_fetch; cmd_check ;;
  upgrade) shift; cmd_upgrade "${1:-}" ;;
  status)  cmd_status ;;
  *)       die "неизвестная команда '$1'. Есть: start | check | upgrade <тег> | status" ;;
esac
