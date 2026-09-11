#!/usr/bin/env bash
# =============================================================================
#  dsh-start-web.sh — запуск dsh web из исходников и управляемый переезд на
#  новые релизы. Единственная запускалка этого хоста.
#
#  Живём всегда в одной ветке (HOST_BRANCH), имя которой НЕ содержит версию.
#  Релизы приезжают внутрь неё слиянием тега: ветка не меняется, профиль не
#  меняется, host-local/ переживает любой апгрейд.
#
#  ──────────────────────────────  КОМАНДЫ  ────────────────────────────────
#
#    dsh-start-web.sh                запустить web (по умолчанию)
#    dsh-start-web.sh --no-open      всё, что не подкоманда, уходит в dsh web
#    dsh-start-web.sh check          проверить новые релизы, ничего не менять
#    dsh-start-web.sh upgrade TAG    влить релизный тег в текущую ветку
#    dsh-start-web.sh status         где мы сейчас
#
#  Релизы апстрима приходят ТЕГАМИ (`dsh-vX.Y.Z-{alpha,beta,rc}.N`), а не
#  ветками: у origin есть только master. Поэтому check ищет среди тегов.
#  Новизна считается достижимостью, а не сравнением имён — влитый тег новым
#  не считается, как бы он ни назывался.
#
#  ─────────────────────────────  ПАРАМЕТРЫ  ───────────────────────────────
#
#  Переменные окружения ставятся ПЕРЕД именем скрипта (это `env`; после
#  имени bash их уже не интерпретирует):
#
#    DSH_PORT=3099 dsh-start-web.sh --port 3099
#
#    DSH_HOST_BRANCH=<ветка>  ветка хоста; вне её скрипт работать отказывается
#    DSH_HOST_PROFILE=<имя>   профиль dsh; по умолчанию `web`, один на хост
#    DSH_PORT=<порт>          порт, который освобождается перед стартом (3080).
#                             Порт самого dsh задаётся отдельно: `--port N`
#    DSH_LOG=console|file|both|none   куда идёт вывод; по умолчанию console
#    DSH_LOG_DIR=<путь>       каталог логов; по умолчанию $HOME/.dsh/logs
#    DSH_LOG_KEEP=<N>         сколько логов хранить; 0 — не удалять (5)
#    DSH_SKIP_SYNC=1          не синхронизировать плагины профиля перед стартом
#    DSH_NO_ARCH_PIN=1        не трогать supportedArchitectures в профиле
#    DSH_NETWORK_CONCURRENCY=<N>   параллельность закачек pnpm (4)
#    DSH_INSTALL_ATTEMPTS=<N>      попыток установки при сетевых сбоях (5)
#    DSH_REFRESH_FREE_MODELS=always|never|force   список :free моделей
#                             OpenRouter в ~/.dsh/settings.yaml (always)
#    DSH_UPSTREAM_REMOTE / DSH_FORK_REMOTE / DSH_RELEASE_TAG_GLOB
#
#  История: до слияния запускалок было две — ~/.dsh/start-web.sh (делал всю
#  работу) и host-local/scripts/dsh-start-web.sh (следил за релизами и
#  делегировал в первую). Первая не версионировалась и жила вне репозитория,
#  из-за чего правки под релиз терялись из виду. Теперь одна, в ветке.
# =============================================================================
set -Eeuo pipefail

# ── конфигурация ──────────────────────────────────────────────────────

# Ветка, в которой живёт этот хост. Имя без версии: идентичность ветки —
# «этот хост», а не «этот релиз».
HOST_BRANCH="${DSH_HOST_BRANCH:-host/uadmin-raider18}"

# Профиль dsh — один на хост. Профили вида `web-<ветка>` упразднены: каждый
# был копией на 700+ МБ, жившей своей жизнью, и правка в одном не была видна
# другим.
PROFILE="${DSH_HOST_PROFILE:-web}"

UPSTREAM_REMOTE="${DSH_UPSTREAM_REMOTE:-origin}"
FORK_REMOTE="${DSH_FORK_REMOTE:-fork}"
RELEASE_TAG_GLOB="${DSH_RELEASE_TAG_GLOB:-dsh-v*}"

PORT="${DSH_PORT:-3080}"
LOG_MODE="${DSH_LOG:-console}"
LOG_DIR="${DSH_LOG_DIR:-$HOME/.dsh/logs}"
LOG_KEEP="${DSH_LOG_KEEP:-5}"

# ── пути ──────────────────────────────────────────────────────────────

# readlink -f обязателен: скрипт вызывается через симлинки (~/.dsh/ и
# ~/.local/bin/), и без разыменования $BASH_SOURCE указывал бы на каталог
# симлинка — то есть на $HOME, а не на репозиторий.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"

HOST_DIR="$REPO_ROOT/host-local"
STATE_DIR="$HOST_DIR/state"
CURRENT_RELEASE_FILE="$STATE_DIR/current-release"
SEEN_TAGS_FILE="$STATE_DIR/seen-tags"
RELEASE_LOG="$HOST_DIR/docs/release-log.md"
PROFILE_DIR="$HOME/.dsh/profiles/$PROFILE"
GIT_EXCLUDE_SRC="$HOST_DIR/git-exclude"
GIT_EXCLUDE_MARK="# >>> host-local git-exclude"

# Плагины и пресеты читают DSH_REPO. Источник правды — расположение самого
# скрипта, а не запись в ~/.env: скрипт лежит В репозитории, так что
# разойтись они не могут.
export DSH_REPO="$REPO_ROOT"

cd "$REPO_ROOT"

# Пользовательский .env — ключи для плагинов (DEEPSEEK_API_KEY и прочее),
# которые читаются в момент монтирования. Молча пропускаем, если файла нет.
if [ -f "$HOME/.env" ]; then
  # shellcheck source=/dev/null
  set -a; . "$HOME/.env"; set +a
fi

# У `dsh web` своих флагов логирования нет, поэтому внятный стек вместо
# голого кода выхода даёт только Node. `--trace-warnings` намеренно НЕ
# включён: он печатал 15-строчный стек на каждое ExperimentalWarning от
# code-runtime. `--disable-warning` глушит ровно этот класс.
export NODE_OPTIONS='--trace-uncaught --stack-trace-limit=50 --disable-warning=ExperimentalWarning'
export UV_HTTP_TIMEOUT=300

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

# Git с настроенной сортировкой предрелизов: без этого versionsort ставит
# dsh-v0.1.5-rc.1 ВЫШЕ dsh-v0.1.5, и «последний тег» оказывается неверным.
git_v() {
  git -c versionsort.suffix=-alpha \
      -c versionsort.suffix=-beta \
      -c versionsort.suffix=-rc \
      "$@"
}

# ── проверки ──────────────────────────────────────────────────────────

# Жить и запускаться только внутри своей ветки: запуск с чужой собрал бы не
# тот код в тот же профиль.
assert_host_branch() {
  local current
  current="$(git rev-parse --abbrev-ref HEAD)"
  [ "$current" = "$HOST_BRANCH" ] || die \
    "сейчас ветка '$current', а жить надо в '$HOST_BRANCH'. Переключись: git switch $HOST_BRANCH"
}

worktree_is_dirty() {
  [ -n "$(git status --porcelain --untracked-files=no)" ]
}

# ── локальные ignore-правила ──────────────────────────────────────────

# Ставим правила в .git/info/exclude, а НЕ в корневой .gitignore: тот
# принадлежит апстриму, и наша строка в нём однажды даст конфликт слияния.
# Обратная сторона — .git/info/exclude не версионируется и не переживает
# clone, поэтому источник правды лежит в ветке (host-local/git-exclude), а
# сюда он копируется при каждом запуске.
sync_git_exclude() {
  [ -f "$GIT_EXCLUDE_SRC" ] || return 0
  local dst="$REPO_ROOT/.git/info/exclude"
  mkdir -p "$(dirname "$dst")"
  touch "$dst"

  # Свой блок узнаём по маркеру и переписываем целиком — так правка
  # host-local/git-exclude доезжает, а чужие строки не трогаются.
  local tmp
  tmp="$(mktemp)"
  sed "/^${GIT_EXCLUDE_MARK}$/,/^# <<< host-local git-exclude$/d" "$dst" > "$tmp"
  {
    echo "$GIT_EXCLUDE_MARK"
    echo "# Генерируется из host-local/git-exclude. Правь ТАМ, не здесь."
    cat "$GIT_EXCLUDE_SRC"
    echo "# <<< host-local git-exclude"
  } >> "$tmp"
  mv "$tmp" "$dst"
}

# ── освобождение порта ────────────────────────────────────────────────

# По слушающему порту, а не по шаблону командной строки: `dsh` — симлинк, и
# Node оставляет в argv[1] путь вызова, а не цель симлинка, поэтому pkill по
# `apps/cli/lib/bin.js` живой процесс не находит.
#
# Замыкающий `|| true` обязателен: без совпадений grep возвращает 1, и под
# `set -o pipefail` это уронило бы весь скрипт.
port_pids() {
  ss -ltnpH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true
}

stop_previous() {
  local pids i
  pids=$(port_pids "$PORT")
  if [ -z "$pids" ]; then
    log "порт $PORT свободен"
    return 0
  fi
  # dsh обрабатывает SIGTERM и гасится штатно; KILL — только добивание.
  log "останавливаю на порту $PORT: $(echo "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086  # намеренное разбиение списка pid на слова
  kill -TERM $pids 2>/dev/null || true
  for i in $(seq 1 20); do
    sleep 0.5
    if [ -z "$(port_pids "$PORT")" ]; then
      log "остановлено"
      return 0
    fi
  done
  pids=$(port_pids "$PORT")
  warn "за 10 с не завершились, добиваю: $(echo "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null || true
  sleep 1
  [ -z "$(port_pids "$PORT")" ] || die "порт $PORT всё ещё занят"
  log "остановлено"
}

# ── платформенные зависимости ─────────────────────────────────────────

# pnpm и по умолчанию ставит optional-зависимости только текущей платформы;
# блок ниже фиксирует это явно, чтобы поведение не расширила чужая настройка.
# Ключ читается ТОЛЬКО из pnpm-workspace.yaml: форму supported-architectures.*
# в .npmrc pnpm 11 игнорирует.
ensure_arch_pin() {
  [ "${DSH_NO_ARCH_PIN:-0}" = 1 ] && return 0
  local ws="$PROFILE_DIR/pnpm-workspace.yaml"
  [ -f "$ws" ] || return 0
  grep -q '^supportedArchitectures:' "$ws" && return 0

  local os cpu libc
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *)      os=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  cpu=x64 ;;
    aarch64|arm64) cpu=arm64 ;;
    *)             cpu=$(uname -m) ;;
  esac
  if ldd --version 2>&1 | grep -qi musl; then libc=musl; else libc=glibc; fi

  {
    echo
    echo "# Платформенные (optional) зависимости — только текущая машина."
    echo "# Добавлено dsh-start-web.sh."
    echo "supportedArchitectures:"
    echo "  os:"
    echo "    - $os"
    echo "  cpu:"
    echo "    - $cpu"
    echo "  libc:"
    echo "    - $libc"
  } >> "$ws"
  log "в $ws добавлен supportedArchitectures: $os/$cpu/$libc"
}

# ── ротация логов ─────────────────────────────────────────────────────

# Через массив, а не `ls | tail | xargs`: несовпавший glob даёт ls код 2, что
# под `set -o pipefail` прервало бы запуск.
prune_logs() {
  [ "$LOG_KEEP" -gt 0 ] || return 0
  local files=() i
  mapfile -t files < <(ls -1t -- "$LOG_DIR"/dsh-web-*.log 2>/dev/null || true)
  for ((i = LOG_KEEP; i < ${#files[@]}; i++)); do
    rm -f -- "${files[i]}"
  done
}

new_log_path() {
  mkdir -p "$LOG_DIR"
  prune_logs
  echo "$LOG_DIR/dsh-web-$(date +%F_%H%M%S).log"
}

# ── установка зависимостей ────────────────────────────────────────────

# Релиз тянет сотни мегабайт (@openai/codex — 129 МБ, claude-agent-sdk — 97
# МБ), и одиночный `pnpm install` на нестабильной сети падает почти всегда:
# видно шторм ETIMEDOUT к registry.npmjs.org, затем «TypeError: fetch
# failed». Поэтому установка — цикл, а не одна команда.
#
# network-concurrency понижена намеренно: 16 параллельных соединений по
# умолчанию как раз и создают таймауты, при 4 закачка идёт медленнее, но
# доходит. Ретраи дешёвые — pnpm переиспользует уже скачанное из store.
#
# Первый аргумент — каталог установки ('' = корень репозитория), остальные
# уходят в pnpm. `--prefix` обязан стоять ДО подкоманды `install`: после неё
# pnpm его не разбирает.
install_deps() {
  local dir="${1:-}"; shift || true
  local attempts="${DSH_INSTALL_ATTEMPTS:-5}" i delay
  local prefix=()
  [ -n "$dir" ] && prefix=(--prefix "$dir")

  for ((i = 1; i <= attempts; i++)); do
    log "установка зависимостей (попытка $i из $attempts)${dir:+ — $dir}"
    if pnpm "${prefix[@]}" install "$@" \
         --network-concurrency "${DSH_NETWORK_CONCURRENCY:-4}" \
         --fetch-retries 5 \
         --fetch-retry-mintimeout 20000 \
         --fetch-retry-maxtimeout 120000 \
         --fetch-timeout 300000; then
      return 0
    fi
    [ "$i" -lt "$attempts" ] || break
    delay=$((i * 20))
    warn "установка сорвалась; повтор через ${delay}с (скачанное сохранено)"
    sleep "$delay"
  done
  return 1
}

# ── релизы ────────────────────────────────────────────────────────────

current_release() {
  if [ -s "$CURRENT_RELEASE_FILE" ]; then
    cat "$CURRENT_RELEASE_FILE"
  else
    # Ещё ни разу не апгрейдились этим скриптом — спрашиваем сам git.
    git_v describe --tags --abbrev=0 --match "$RELEASE_TAG_GLOB" 2>/dev/null || echo "unknown"
  fi
}

# Предрелизная версия означает, что апстрим ломает API без предупреждения:
# именно на 0.1.2-alpha.1 уехали dsh-client-runtime и ApiProxy, из-за чего
# разом отвалились 16 из 18 плагинов @linxin666.
stability_of() {
  case "$1" in
    *-alpha*) echo "alpha — ломающие изменения ожидаемы" ;;
    *-beta*)  echo "beta — API ещё может меняться" ;;
    *-rc*)    echo "rc — относительно стабилен" ;;
    '')       echo "неизвестно" ;;
    *)        echo "стабильный релиз" ;;
  esac
}

# Все релизные теги новее текущего. Новизна — по достижимости, не по имени.
newer_releases() {
  local tag
  git_v tag --list "$RELEASE_TAG_GLOB" --sort=v:refname | while read -r tag; do
    [ -n "$tag" ] || continue
    if ! git merge-base --is-ancestor "$tag" HEAD 2>/dev/null; then
      echo "$tag"
    fi
  done
}

# Фиксация факта появления релиза. Отдельно от факта переезда: увидеть релиз
# и переехать на него — разные события, и лог должен их различать.
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

Пишется скриптом `host-local/scripts/dsh-start-web.sh`. Строка «замечен» —
релиз появился в апстриме; строка «переезд» — мы на него перешли.

| дата | событие | тег | заметка |
|---|---|---|---|
HEADER
  printf '| %s | %s | `%s` | %s |\n' "$(date -Is)" "$kind" "$tag" "$note" >> "$RELEASE_LOG"
}

# ── подготовка профиля ────────────────────────────────────────────────

prepare_profile() {
  # Профиль единственный и постоянный: клонировать его больше не из чего и
  # незачем. Если он исчез — это авария, а не повод молча собрать пустышку.
  if [ ! -d "$PROFILE_DIR" ]; then
    warn "профиль не найден: $PROFILE_DIR"
    printf '   восстанови из бэкапа:\n' >&2
    printf '     tar --zstd -xf ~/.dsh/_archive/profiles-backup-<дата>.tar.zst -C ~/.dsh/profiles\n' >&2
    printf '     pnpm --prefix %s install --no-frozen-lockfile --no-strict-peer-dependencies\n' "$PROFILE_DIR" >&2
    exit 1
  fi

  ensure_arch_pin

  # Здесь писался patch-loader.mjs — ESM-хук, подменявший dsh-settings
  # заглушкой. Он ни разу не подключался (NODE_OPTIONS его не импортирует),
  # то есть был мёртвым кодом, уводящим по ложному следу при разборе падений
  # импорта. Удаляем остатки.
  rm -f "$PROFILE_DIR/patch-loader.mjs"

  if [ "${DSH_SKIP_SYNC:-0}" != 1 ] && [ -f "$PROFILE_DIR/package.json" ]; then
    log "синхронизация плагинов профиля: $PROFILE_DIR"
    install_deps "$PROFILE_DIR" --no-frozen-lockfile --no-strict-peer-dependencies \
      || die "не удалось синхронизировать плагины профиля"
  fi

  fix_preset_paths
  patch_llm_callid_alias
  patch_plugin_ad_settings_api
  install_settings_shim
}

# dsh_plugin_ad: свободная функция installSettingsSection стала методом.
#
# Ни шим в профиле, ни патч сборки этот импорт не перехватывают.
# Приложение запускается через `tsx/esm`, а tsconfig.base.json:377 маппит
# `@deepseek-ai/dsh-settings` на `packages/settings/settings/src` — и
# перенаправление действует на ВСЕ загружаемые модули, включая плагины вне
# репозитория. Этот `src` — отслеживаемый апстримовый исходник, править его
# ради своей нужды нельзя.
#
# Поэтому чиним со стороны плагина: `lib/` у dsh_plugin_ad не отслеживается
# даже его собственным git — это артефакт сборки в нашей коллекции.
#
# Заглушкой не обходимся: в 0.1.5 функция не исчезла, а переехала в
# SettingsProvider.installSection с той же семантикой. Старое тело
# оборачивало вызов в ctx.inject(['settings']) — адаптер делает ровно это,
# поэтому секция настроек плагина продолжает работать, а не молча пропадает.
patch_plugin_ad_settings_api() {
  local lib="$REPO_ROOT/../dsh-plugins-collection/dsh_plugin_ad/lib/index.js"
  [ -f "$lib" ] || return 0
  grep -q 'host-local: settings API adapter' "$lib" && return 0
  grep -q 'installSettingsSection.*from "@deepseek-ai/dsh-settings"' "$lib" || return 0

  log "адаптер settings-API для dsh_plugin_ad"
  local tmp
  tmp="$(mktemp)"
  {
    echo '// host-local: settings API adapter — installSettingsSection стала'
    echo '// SettingsProvider.installSection. Дописывается dsh-start-web.sh при'
    echo '// каждом старте, потому что lib/ пересобирается обновлением плагина.'
    echo 'function settingsNamespace(value) {'
    echo '  if (!/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/.test(value)) {'
    echo '    throw new TypeError(`settings namespace "${value}" is not lowercase-hyphenated`);'
    echo '  }'
    echo '  return value;'
    echo '}'
    echo 'function installSettingsSection(ctx, ns, schema, entry, hooks) {'
    echo '  ctx.inject(["settings"], (sctx) => {'
    echo '    sctx.settings.installSection(ctx, ns, schema, entry, hooks);'
    echo '  });'
    echo '}'
    # Исходный импорт убираем целиком: обе его имени теперь локальные, а
    # других имён из этого модуля файл не берёт (проверено — импорт один).
    sed '1{/^import { installSettingsSection, settingsNamespace } from "@deepseek-ai\/dsh-settings";$/d}' "$lib"
  } > "$tmp"
  mv "$tmp" "$lib"
}


# Пресеты агентов ссылаются на исходники по АБСОЛЮТНОМУ пути: loader-строки
# `path:` не проходят интерполяцию, $DSH_REPO там не развернётся. Поэтому
# путь подшивается сюда из той же переменной — источник правды один.
fix_preset_paths() {
  local std_preset="$REPO_ROOT/packages/preset/agent-presets/presets/standard/agent.cordis.yml"
  local preset_file
  for preset_file in "$HOME"/.dsh/.agent-presets/*/agent.cordis.yml; do
    [ -f "$preset_file" ] || continue
    sed -i -E "s#path: .*/packages/preset/#path: ${REPO_ROOT}/packages/preset/#" "$preset_file"
    # dsh-rlm-mode поставляет пресет с НЕразрешённым плейсхолдером вместо
    # пути: в апстриме его подставляет install.sh, которого у нас нет.
    # Строка выше его не ловит — в плейсхолдере нет /packages/preset/.
    sed -i "s#path: DASHR_PLACEHOLDER_standard_preset_path_install_script_required#path: ${std_preset}#" "$preset_file"
  done
}

# dsh-rlm-mode@0.1.6 собран против dsh-llm 0.1.0-rc.6, где бренд назывался
# CallId; позже он переименован в ToolCallId, и ESM-импорт падает с
# SyntaxError ДО того, как loader смотрит disabled. Бренды существуют только
# в типах (brandString — тождественная функция), поэтому алиас
# рантайм-эквивалентен. lib/ пересобирается — дописываем каждый старт.
patch_llm_callid_alias() {
  local llm_lib="$REPO_ROOT/packages/llm/llm/lib/index.js"
  if [ -f "$llm_lib" ] && ! grep -q "ToolCallId as CallId" "$llm_lib"; then
    log "дописываю алиас CallId в dsh-llm (для dsh-rlm-mode)"
    printf '\nexport { ToolCallId as CallId };\n' >> "$llm_lib"
  fi
}

# @deepseek-ai/dsh-settings для плагинов профиля.
#
# Плагины лежат в node_modules профиля и резолвят пакет оттуда же — до
# пакетов репозитория подъём по каталогам не доходит. Раньше сюда клалась
# заглушка с двумя экспортами; заглушка — это пин версии, и на первом же
# апгрейде она выстрелила: 0.1.5-rc.2 добавил SettingsConflictError (его
# импортирует dsh-better-sidebar) и убрал installSettingsSection (его
# импортирует dshmarket). Заглушка ломает первого, голая ссылка — второго.
#
# Поэтому шим: ре-экспорт настоящего пакета целиком плюс дописка только тех
# устаревших экспортов, которых в текущем релизе действительно нет. Проверка
# обязательна — если релиз вернёт такой экспорт, безусловная дописка дала бы
# дубль и SyntaxError.
install_settings_shim() {
  local pkg="$REPO_ROOT/packages/settings/settings"
  local shim="$PROFILE_DIR/node_modules/@deepseek-ai/dsh-settings"

  if [ ! -f "$pkg/lib/index.js" ]; then
    warn "$pkg/lib не собран — плагины, импортирующие dsh-settings, упадут"
    printf '   собери репозиторий: pnpm run build\n' >&2
    return 0
  fi

  local version
  version="$(node -p "require('$pkg/package.json').version")"
  log "шим dsh-settings поверх репозитория ($version)"

  rm -rf "$shim"
  mkdir -p "$shim"
  cat > "$shim/package.json" <<EOF
{
  "name": "@deepseek-ai/dsh-settings",
  "version": "$version",
  "type": "module",
  "main": "index.js"
}
EOF
  {
    echo "// Генерируется host-local/scripts/dsh-start-web.sh. Правки бессмысленны."
    echo "export * from '$pkg/lib/index.js';"
    node -e "
      import('$pkg/lib/index.js').then((m) => {
        if (!('installSettingsSection' in m)) {
          console.log('export function installSettingsSection() { return () => {}; }');
        }
        if (!('settingsNamespace' in m)) {
          console.log(\"export const settingsNamespace = 'settings';\");
        }
      });
    "
  } > "$shim/index.js"
  log "  экспортов совместимости дописано: $(grep -c '^export \(function\|const\)' "$shim/index.js")"
}

# ── команды ───────────────────────────────────────────────────────────

cmd_fetch() {
  log "git fetch $UPSTREAM_REMOTE (теги релизов)"
  git fetch --tags --prune "$UPSTREAM_REMOTE" || warn "fetch $UPSTREAM_REMOTE не удался, продолжаю"
  if git remote | grep -qx "$FORK_REMOTE"; then
    git fetch --prune "$FORK_REMOTE" || warn "fetch $FORK_REMOTE не удался, продолжаю"
  fi
}

# git pull только если у ветки есть upstream: у чисто локальной ветки pull
# падает, и это не повод прерывать запуск.
cmd_pull() {
  if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    git pull --ff-only || warn "pull не прошёл fast-forward, ветка расходится с upstream"
  fi
}

cmd_check() {
  local cur new_count=0 fresh=() tag
  cur="$(current_release)"
  log "текущий релиз: $cur — $(stability_of "$cur")"

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
  while read -r tag; do
    [ -n "$tag" ] || continue
    printf '      %-22s %s\n' "$tag" "$(stability_of "$tag")"
  done < <(newer_releases)
  if [ "${#fresh[@]}" -gt 0 ]; then
    warn "впервые вижу: ${fresh[*]} (записано в host-local/docs/release-log.md)"
  fi
  printf '      переезд:  %s upgrade <тег>\n' "${SELF##*/}"
}

cmd_upgrade() {
  local tag="${1:-}"
  [ -n "$tag" ] || die "нужен тег: ${SELF##*/} upgrade dsh-v0.1.5-rc.2"
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
    || die "тега '$tag' нет локально — сделай '${SELF##*/} check'"

  assert_host_branch

  # Слияние уже влитого тега — не ошибка, а обычный повтор: установка тянет
  # сотни мегабайт и падает от любого сетевого чиха. Тогда переезд
  # доделывается тем же вызовом, без второго мерджа и второго бэкапа.
  if git merge-base --is-ancestor "$tag" HEAD 2>/dev/null; then
    log "$tag уже влит — доделываю установку и сборку"
  else
    worktree_is_dirty && die "рабочее дерево грязное — закоммить или спрячь перед переездом"

    # Точка возврата: слияние релиза затрагивает тысячи файлов, откат через
    # reflog возможен, но именованная ветка надёжнее.
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

    # Бухгалтерию коммитим сразу. Иначе скрипт оставляет после себя
    # изменённый release-log.md и на следующем запуске спотыкается о
    # собственную запись: «рабочее дерево грязное».
    git add host-local/docs/release-log.md
    git commit -q -m "host-local: record upgrade to $tag" || true
  fi

  # Установка и сборка — не транзакция: сеть отваливается на середине
  # закачки. Падение здесь не откатывает мердж, а просит повторить команду.
  if ! install_deps ""; then
    warn "установка не прошла даже с ретраями — похоже, сеть недоступна."
    printf '      повтори ту же команду: %s upgrade %s\n' "${SELF##*/}" "$tag"
    printf '      или помедленнее:      DSH_NETWORK_CONCURRENCY=2 %s upgrade %s\n' "${SELF##*/}" "$tag"
    exit 1
  fi

  log "собираю"
  if ! pnpm run build; then
    warn "сборка не прошла — смотри вывод выше."
    printf '      повтор:  %s upgrade %s\n' "${SELF##*/}" "$tag"
    exit 1
  fi

  log "переехали на $tag. Профиль '$PROFILE' не тронут."
  printf '      откат при проблемах: git reset --hard %s\n' \
    "$(git branch --list 'backup/*' | tail -1 | tr -d ' *')"
}

cmd_status() {
  local cur pending
  cur="$(current_release)"
  printf 'ветка:    %s (%s)\n' "$(git rev-parse --abbrev-ref HEAD)" "$(git rev-parse --short HEAD)"
  printf 'релиз:    %s — %s\n' "$cur" "$(stability_of "$cur")"
  printf 'профиль:  %s\n' "$PROFILE_DIR"
  printf 'дерево:   %s\n' "$(worktree_is_dirty && echo 'грязное' || echo 'чистое')"
  pending="$(newer_releases | tr '\n' ' ')"
  printf 'новее:    %s\n' "${pending:-нет}"
}

cmd_start() {
  assert_host_branch
  worktree_is_dirty && warn "рабочее дерево грязное — запускаю как есть"

  log "$(date -Is) start — ветка $HOST_BRANCH ($(git rev-parse --short HEAD))"
  stop_previous
  cmd_fetch
  cmd_pull
  cmd_check || true

  # Список :free моделей OpenRouter. Логика в отдельном файле, чтобы её
  # можно было гонять руками, не перезапуская веб-морду. Не блокирует старт.
  if [ -f "$HOME/.dsh/refresh-free-models.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.dsh/refresh-free-models.sh"
    refresh_openrouter_free_models || warn "обновление списка free-моделей не удалось"
  fi

  prepare_profile

  log "$(date -Is) dsh --profile $PROFILE"
  export DSH_PROFILE_PATH="$PROFILE_DIR"
  export DSH_REPO_PATH="$REPO_ROOT"
  # URL с разовым токеном печатает сам dsh; скрипт его не перехватывает,
  # чтобы токен не оседал в логах.
  exec pnpm exec node --import tsx/esm apps/cli/src/bin.ts --profile "$PROFILE" "$@"
}

# ── диспетчер ─────────────────────────────────────────────────────────

# Раньше всего остального: без актуального exclude «грязное дерево» может
# оказаться ложным, и upgrade откажется работать на ровном месте.
sync_git_exclude

# Первый аргумент — подкоманда только если он ею является. Всё остальное
# уходит в `dsh web` как есть, чтобы `dsh-start-web.sh --no-open` работал.
run_with_logging() {
  case "$LOG_MODE" in
    console) cmd_start "$@" ;;
    none)    cmd_start "$@" >/dev/null 2>&1 ;;
    file)    LOG=$(new_log_path); echo "лог: $LOG"; cmd_start "$@" >"$LOG" 2>&1 ;;
    both)    LOG=$(new_log_path); echo "лог: $LOG"; cmd_start "$@" 2>&1 | tee "$LOG" ;;
    *)       die "DSH_LOG: ожидается console|file|both|none, получено '$LOG_MODE'" ;;
  esac
}

case "${1:-}" in
  check)   shift; assert_host_branch; cmd_fetch; cmd_check ;;
  upgrade) shift; cmd_upgrade "${1:-}" ;;
  status)  shift; cmd_status ;;
  start)   shift; run_with_logging "$@" ;;
  *)       run_with_logging "$@" ;;
esac
