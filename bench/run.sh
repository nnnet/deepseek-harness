#!/usr/bin/env bash
# Node A4 of .claude/plans/2026-08-27T20-36__dsh-local-qwen38-optimization.md.
#
# One reference-task run against `dsh --profile bench`, in a clean workspace,
# gated by bench/gate.mjs, measured by bench/metrics.py, appended as one row
# to bench/ledger.md.
#
# Usage: bench/run.sh [label] [-- --patch extra-overlay.yml ...]
#   label            ledger column identifying the lever under test (default: baseline)
#   extra --patch    additional overlays layered after bench/overlays/rlm-mode.yml
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="$REPO_ROOT/bench"
WORKSPACE="$HOME/.dsh/bench-workspace"
LEDGER="$BENCH_DIR/ledger.md"
BASE_OVERLAY="$BENCH_DIR/overlays/rlm-mode.yml"
SESSIONS_ROOT="$HOME/.dsh/sessions"

LABEL="${1:-baseline}"
[ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift
EXTRA_PATCH_ARGS=("$@")

# task.md ## Промпт агенту — подаётся дословно, единственным сообщением.
TASK_PROMPT=$(cat <<'PROMPT'
Напиши плагин dsh по образцу установленного `@linxin666/dsh-pet` — он показывает состояние виртуального питомца.

Положи пакет в `./dsh-pet-lite/` относительно рабочего каталога. Требования:

1. Чистый ESM JavaScript, `"type": "module"` в `package.json`. Сборки нет — файл грузится как есть.
2. Никаких зависимостей, кроме встроенных модулей Node.
3. Форма плагина — функциональная: именованные экспорты `name`, `inject`, `apply`. Default-экспорта быть не должно: смешение двух форм заставляет загрузчик отбросить namespace функционального плагина.
4. `inject` содержит `'tools'`.
5. `apply(ctx)` регистрирует ровно один инструмент вызовом `ctx.tools.register(definition)`.
6. Определение инструмента:
   - `name`: `'pet_status'`
   - `description`: непустая строка
   - `parameters`: JSON Schema объекта без обязательных полей — `{ type: 'object', properties: {} }`
   - `output.schema`: `{ type: 'string' }`
   - `output.render(args, value)`: возвращает `[{ type: 'text', text: value }]`
   - `async execute(args, exec)`: читает JSON-файл `.dsh/pet.json` в домашнем каталоге и возвращает **строку** вида `«<имя> — visible»` или `«<имя> — hidden»`.

Правила формирования строки:

- `<имя>` — это `names[petId]`, если такой ключ есть, иначе сам `petId`;
- суффикс `visible`, если `display.visible` истинно, иначе `hidden`;
- разделитель — пробел, тире, пробел (` — `);
- домашний каталог берётся через `os.homedir()`, а не хардкодом пути.

Пример файла и ожидаемого результата:

```json
{ "petId": "otter", "names": { "otter": "Выдра" }, "display": { "visible": true } }
```

даёт строку `Выдра — visible`.
PROMPT
)

mkdir -p "$WORKSPACE"
rm -rf "${WORKSPACE:?}"/* "${WORKSPACE:?}"/.[!.]* 2>/dev/null

KEY_DIR="$SESSIONS_ROOT/--$(echo "${WORKSPACE#/}" | sed 's#/#-#g')--"
mkdir -p "$KEY_DIR"
MARKER="$(mktemp)"
sleep 1.1 # ensure the marker mtime is strictly older than any session dir dsh is about to create
touch "$MARKER"

echo "run.sh: label=$LABEL workspace=$WORKSPACE overlay=$BASE_OVERLAY extra=${EXTRA_PATCH_ARGS[*]:-}" >&2
START_EPOCH=$(date +%s)
( cd "$WORKSPACE" && dsh --profile bench --patch "$BASE_OVERLAY" "${EXTRA_PATCH_ARGS[@]}" "$TASK_PROMPT" )
DSH_EXIT=$?
END_EPOCH=$(date +%s)
echo "run.sh: dsh exit=$DSH_EXIT elapsed=$((END_EPOCH - START_EPOCH))s" >&2

NEW_SESSION_DIR=$(find "$KEY_DIR" -mindepth 1 -maxdepth 1 -type d -newer "$MARKER" | sort | tail -1)
rm -f "$MARKER"

if [ -z "$NEW_SESSION_DIR" ]; then
  echo "run.sh: no new session directory under $KEY_DIR — dsh did not produce a session log" >&2
  exit 1
fi

GATE_TARGET="$WORKSPACE/dsh-pet-lite"
GATE_EXIT=0
node "$BENCH_DIR/gate.mjs" "$GATE_TARGET" || GATE_EXIT=$?
GATE_BIT=0
[ "$GATE_EXIT" -eq 0 ] && GATE_BIT=1

METRICS_TSV=$(python3 "$BENCH_DIR/metrics.py" "$NEW_SESSION_DIR") || {
  echo "run.sh: metrics.py failed on $NEW_SESSION_DIR" >&2
  exit 1
}
IFS=$'\t' read -r WALL STEPS IN_MED IN_MAX THINK_RATIO TOOL_ERR COMPACTIONS <<< "$METRICS_TSV"

SESSION_ID="$(basename "$NEW_SESSION_DIR")"
TIMESTAMP="$(date -Iseconds)"

if [ ! -s "$LEDGER" ]; then
  {
    echo "| timestamp | lever | session | wall | steps | in_med | in_max | think_ratio | tool_err | compactions | gate |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
  } > "$LEDGER"
fi
echo "| $TIMESTAMP | $LABEL | $SESSION_ID | $WALL | $STEPS | $IN_MED | $IN_MAX | $THINK_RATIO | $TOOL_ERR | $COMPACTIONS | $GATE_BIT |" >> "$LEDGER"

echo "run.sh: wall=$WALL steps=$STEPS in_med=$IN_MED in_max=$IN_MAX think_ratio=$THINK_RATIO tool_err=$TOOL_ERR compactions=$COMPACTIONS gate=$GATE_BIT session=$SESSION_ID"
