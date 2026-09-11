# MCP Ouroboros: как пользоваться в Claude Code и в dsh

Ouroboros — spec-first движок рабочих процессов, который подключается к
агенту по MCP. Вместо «напиши код по промпту» он навязывает цикл
**интервью → Seed → исполнение → оценка → эволюция**, где каждый виток
проверяется против записанных критериев приёмки.

Мануал описывает обе плоскости интеграции — плагин Claude Code и бандл dsh —
и показывает один и тот же сценарий в каждой из них.

Проверено против того, что реально стоит на этой машине:
Claude Code плагин `ouroboros@ouroboros` **0.53.0** и dsh-бандл
`dsh-ouroboros` в профиле `web-pin-dsh-v0.1.2-rc.1`.

- Апстрим: <https://github.com/Q00/ouroboros>
- PyPI: `ouroboros-ai[mcp]`

---

## 1. Модель работы

### Цикл

```
  ┌─ interview ── Сократовский опрос, снимает неоднозначность
  │                    │
  │                    ▼
  │              generate_seed ── неизменяемая спецификация (YAML)
  │                    │              gate: ambiguity_score ≤ 0.2
  │                    ▼
  │              execute_seed ── исполнение по acceptance_criteria
  │                    │
  │                    ▼
  │              evaluate ── 3 стадии проверки
  │                    │
  │                    ├── принято → готово
  │                    ▼
  └──────────── evolve / ralph ── правки и следующая генерация
```

### Seed — центральный артефакт

Seed фиксирует намерение так, чтобы его можно было проверить машиной.
Канонический пример из поставки (`examples/dummy_seed.yaml`):

```yaml
goal: "Create a simple Python hello world script with tests"

constraints:
  - "Python >= 3.12"
  - "Use pytest for testing"

acceptance_criteria:
  - "Create a hello.py file with a greet() function that returns 'Hello, {name}!'"
  - "All tests must pass when running pytest"

ontology_schema:
  name: "HelloWorld"
  description: "Simple hello world domain"
  fields:
    - name: "greeting"
      field_type: "string"
      description: "The greeting message"

metadata:
  seed_id: "dummy_test_001"
  ambiguity_score: 0.1
```

Ключевое: **`acceptance_criteria` — это проверяемые условия, а не пожелания.**
«Сделать хорошо» не критерий; «`pytest` проходит», «эндпоинт отдаёт 200 на
валидный payload» — критерии. От их качества зависит всё остальное, потому что
именно по ним потом идёт автоматическая оценка и решение «принято/на доработку».

`ambiguity_score` ≤ **0.2** — гейт. Выше — генерация Seed отклоняется, надо
дозадать вопросы. Обойти можно `force: true`, но реальный score всё равно
попадёт в метаданные Seed'а и в аудит-лог.

### Три стадии оценки

| Стадия | Что делает |
|---|---|
| 1. Mechanical | lint/build/test по `.ouroboros/mechanical.toml` в корне проекта. Файла нет — движок один раз читает манифесты (`package.json`, `pyproject.toml`, `Cargo.toml`, `Makefile`) и пишет toml сам. Не написал — стадия **пропускается целиком**, догадок не строит |
| 2. Semantic | соответствие каждому AC и цели, по одному AC независимо |
| 3. Consensus | несколько моделей голосуют; включается при неуверенности стадии 2 или по `trigger_consensus: true` |

---

## 2. Claude Code

### Установка

```bash
claude plugin marketplace add Q00/ouroboros
claude plugin install ouroboros@ouroboros
```

Затем внутри сессии Claude Code:

```
/ouroboros:setup
```

Единственная внешняя зависимость — **`uv`**. MCP-сервер не ставится в систему:

```json
{
  "mcpServers": {
    "ouroboros": {
      "command": "uvx",
      "args": [
        "--isolated", "--python", ">=3.12",
        "--from", "ouroboros-ai[mcp]",
        "ouroboros", "mcp", "serve",
        "--runtime", "claude-cli",
        "--llm-backend", "claude_code"
      ]
    }
  }
}
```

`uvx --isolated` каждый раз поднимает эфемерное окружение — в системный Python
ничего не протекает. `--runtime claude-cli` означает, что исполняет работу
**сам Claude Code**, а Ouroboros выступает дирижёром: ведёт спецификацию,
раздаёт задачи, проверяет результат.

Проверка:

```bash
claude plugin list | grep ouroboros
# в сессии:
/mcp        # ouroboros должен быть connected
```

### Слэш-команды

Плагин 0.53.0 отдаёт 22 скилла:

```
auto  brownfield  cancel  config  evaluate  evolve  help  interview
ooo   pm  publish  qa  ralph  resume-session  run  seed  setup
status  tutorial  unstuck  update  welcome
```

Практически нужны семь:

| Команда | Когда |
|---|---|
| `/ouroboros:ooo <задача>` | универсальный вход, сам выберет режим |
| `/ouroboros:auto <задача>` | полный конвейер: интервью → Seed → запуск |
| `/ouroboros:interview` | только прояснить требования |
| `/ouroboros:seed` | сделать Seed из уже решённого |
| `/ouroboros:run <seed.yaml>` | исполнить готовый Seed |
| `/ouroboros:status` | что сейчас крутится |
| `/ouroboros:unstuck` | застряли — латеральные персоны |

### Пример: от идеи до кода

```
/ouroboros:auto добавить rate limiting в наш FastAPI-сервис
```

Дальше идёт опрос, по одному вопросу за раз:

```
Q: Ограничение по чему — IP клиента, API-ключ, user id?
A: по API-ключу, ключ уже приходит в заголовке X-API-Key

Q: Какие лимиты и на каком окне?
A: 100 запросов в минуту, скользящее окно

Q: Где хранить счётчики — процесс, Redis, БД?
A: Redis, он уже есть в проекте

Q: Что отдавать при превышении?
A: 429 + заголовок Retry-After в секундах
```

Ambiguity падает ниже 0.2 → генерируется Seed примерно такой формы:

```yaml
goal: "Add API-key based rate limiting to the FastAPI service"
constraints:
  - "Use existing Redis connection from app.deps"
  - "Sliding window, 100 requests per minute per API key"
  - "Must not break existing endpoint signatures"
acceptance_criteria:
  - "Requests carrying X-API-Key beyond 100/min receive HTTP 429"
  - "429 responses include a Retry-After header in whole seconds"
  - "Requests under the limit are unaffected (existing tests still pass)"
  - "Counter state lives in Redis, not in process memory"
metadata:
  ambiguity_score: 0.15
```

И запускается исполнение. Прогресс:

```
/ouroboros:status
```

### Прямые вызовы MCP-инструментов

Слэш-команды — обёртки. Под ними ~три десятка инструментов
`mcp__ouroboros__*` (в плагин-режиме полное имя длиннее:
`mcp__plugin_ouroboros_ouroboros__ouroboros_*`). Самые нужные:

| Инструмент | Роль |
|---|---|
| `ouroboros_interview` | старт/продолжение опроса |
| `ouroboros_generate_seed` | Seed из интервью **или** сразу из `session_context` без опроса |
| `ouroboros_start_auto` | весь конвейер фоном, вернёт `auto_session_id` + `job_id` |
| `ouroboros_start_execute_seed` | исполнить готовый Seed фоном |
| `ouroboros_start_evaluate` | 3-стадийная оценка |
| `ouroboros_ralph` | цикл «правь до зелёного», ограниченный `max_generations` |
| `ouroboros_evolve_step` | ровно одна генерация эволюции |
| `ouroboros_job_status` / `job_wait` / `job_result` | опрос фоновой работы |
| `ouroboros_ac_tree_hud` | живое дерево критериев приёмки |
| `ouroboros_lateral_think` | 5 персон: hacker / researcher / simplifier / architect / contrarian |
| `ouroboros_measure_drift` | насколько результат уехал от исходной цели |
| `ouroboros_cancel_job` / `cancel_execution` | остановить |

Полезно знать: `generate_seed` умеет работать **без интервью**. Если цель,
ограничения и критерии уже проговорены в диалоге — передай их в
`session_context`, и Seed соберётся детерминированно, дословно, без второго
круга вопросов.

Инструменты могут быть **отложенными** (схема не загружена и в списке их не
видно). Отсутствие в списке не значит недоступность — движок сам подгружает
схему по запросу.

### Про фоновые задачи

Всё длинное запускается фоном и сразу возвращает `job_id`:

```
start_auto → job_id → job_wait(timeout_seconds: 5) → ... → job_result
```

`job_wait` по умолчанию отдаёт мгновенный снимок; `wait_for: "ac_change"`
разбудит на изменении критериев, `"terminal"` — только на завершении.
Долгие блокирующие ожидания не нужны и вредны: MCP-клиент может отвалиться
по таймауту.

---

## 3. dsh

### Что это за плагин

`dsh-ouroboros` — **config-only бандл**: никакого рантайм-кода, только
`cordis.patch.yml`, который добавляет в композицию строку `mcp-ouroboros`,
монтирующую `@deepseek-ai/dsh-mcp-client` против команды `ouroboros mcp serve`.

Следствия:
- вся логика живёт в MCP-сервере, dsh только его поднимает;
- обновление Ouroboros ≠ обновление плагина: `uvx` тянет свежую версию сам;
- дебажить надо не бандл, а строку композиции.

### Установка

```bash
# 1. Предусловие: uv на PATH
uv --version          # нет — https://docs.astral.sh/uv/

# 2. Установка в профиль
dsh plugin --profile web add "github:Q00/ouroboros#main&path:integrations/dsh-plugin"

# 3. Перезапуск dsh
```

**Важно про профиль.** Ставить надо в тот профиль, который реально работает.
Если dsh запущен на пиннованной ветке, живой профиль называется не `web`, а
`web-<branch>` (например `web-pin-dsh-v0.1.2-rc.1`) — правка `profiles/web`
на запущенный сервер не подействует вообще.

Как проверить, что строка встала:

```bash
dsh --profile <ваш-профиль> --dump-config | grep -A6 mcp-ouroboros
```

### Кто исполняет работу

Ключевое отличие от Claude Code. Переменная `OUROBOROS_AGENT_RUNTIME`:

| Значение | Кто пишет код |
|---|---|
| `host` (по умолчанию) | **модель самого dsh** — та, что выбрана в UI |
| `claude-cli` | внешний Claude Code CLI |
| `codex` | Codex CLI |
| `opencode` | OpenCode |

То есть из коробки dsh+Ouroboros — замкнутый контур: спецификацию ведёт
Ouroboros, а исполняет твоя же модель харнесса. Локальная LM Studio тоже
подойдёт.

Остальные переменные:

| Переменная | Смысл |
|---|---|
| `OUROBOROS_LLM_BACKEND` | какой бэкенд использует сам движок для интервью/оценки |
| `OUROBOROS_DSH_CONFIG_PATH` | путь к конфигу dsh для рантайма `host` |
| `OUROBOROS_DSH_CLI_PATH` | путь к бинарю dsh, если он не на PATH |

### Ловушка с ключами

Подсистема subprocess в dsh **вычищает из окружения дочернего процесса**
всё, что похоже на секрет: имена по маске `/KEY|PASSWORD|SECRET|TOKEN/i` плюс
все `DSH_*`. Плагин отдаёт обратно только явный allowlist, и в поставке это
ровно два имени: `ANTHROPIC_API_KEY` и `DEEPSEEK_API_KEY`.

Нужен третий (`OPENAI_API_KEY`, ключ OpenRouter, что угодно) — придётся
переопределить строку в `cordis.patch.yml` своего профиля. И помнить правило
композиции: **патч заменяет `config` строки целиком**, поэтому надо
переписать весь блок, а не дописать одну строчку:

```yaml
# <профиль>/cordis.patch.yml
- id: mcp-ouroboros
  config:
    command: uvx
    args: ['--isolated', '--python', '>=3.12', '--from', 'ouroboros-ai[mcp]',
           'ouroboros', 'mcp', 'serve']
    env:
      OUROBOROS_AGENT_RUNTIME: host
      ANTHROPIC_API_KEY: !!js process.env.ANTHROPIC_API_KEY
      DEEPSEEK_API_KEY:  !!js process.env.DEEPSEEK_API_KEY
      OPENAI_API_KEY:    !!js process.env.OPENAI_API_KEY   # ← добавленное
    failOnStartupError: false
```

Точный исходный блок бери из
`$DSH_HOME/profiles/<профиль>/node_modules/dsh-ouroboros/cordis.patch.yml` —
копировать надо его, а не этот пример.

### Поведение при сбоях

- `failOnStartupError: false` — если `uv` не найден, **dsh поднимется нормально**,
  просто без инструментов Ouroboros. Тихо. Не ищи ошибку в логе запуска —
  проверяй наличие инструментов.
- Автовосстановления в опубликованной `0.0.1-rc.1` **нет**: упавший MCP-сервер
  сам не поднимется. Лечится перезагрузкой плагина или рестартом dsh.

### Пример в dsh

В чате dsh, обычным сообщением:

```
Прогони через ouroboros: нужен CLI для конвертации CSV → Parquet
с валидацией схемы. Начни с интервью.
```

Модель вызовет `ouroboros_interview`, задаст вопросы, потом
`ouroboros_generate_seed`, потом `ouroboros_start_execute_seed`. Прогресс
видно в UI как обычные tool-call'ы.

Если Seed уже написан руками — можно сразу:

```
Исполни seed из ./specs/csv2parquet.yaml через ouroboros_start_execute_seed,
рабочий каталог — текущий.
```

---

## 4. Конфиг движка (общий для обеих плоскостей)

`~/.ouroboros/config.yaml` — один на пользователя, читается любым рантаймом.
Текущая конфигурация на этой машине **целиком локальная**, весь облачный
блок закомментирован:

```yaml
consensus:
  min_models: 3
  threshold: 0.67           # 2 из 3 достаточно
  models:
    - {role: advocate, model: qwen3.8-27b}
    - {role: devil,    model: gpt-oss-20b}
    - {role: judge,    model: mistral-small-3.2}

orchestrator:
  runtime_backend: host
  permission_mode: acceptEdits
  max_parallel_workers: 3
  use_worktrees: true
  worktree_root: ~/.ouroboros/worktrees

drift:
  warn_threshold: 0.3
  stop_threshold: 0.5

seed:
  verify_command_gate: warn
```

Что здесь стоит понимать:

- **Три модели консенсуса — три разных LM Studio.** Стадия 3 стоит
  трёх инференсов; на локальном железе это ощутимо. Если не нужна —
  не передавай `trigger_consensus: true` и следи, чтобы стадия 2
  не была неуверенной (то есть пиши чёткие AC).
- **`use_worktrees: true`** — параллельные воркеры работают каждый в своём
  git-worktree под `~/.ouroboros/worktrees`. Это то, что делает
  `max_parallel_workers: 3` безопасным: три агента не топчутся в одном
  рабочем дереве.
- **`permission_mode: acceptEdits`** — правки применяются без подтверждения.
  Разумно только вместе с worktrees и git.
- **`drift`** — если результат уезжает от исходной цели больше чем на 0.5,
  цикл останавливается. Защита от «эволюция ушла решать другую задачу».

Правится через `/ouroboros:config` или руками.

---

## 5. Когда это оправдано, а когда нет

**Стоит:**
- задача многошаговая и требования размытые — интервью окупается сразу;
- миграция или рефакторинг, где «сделано» надо доказать, а не почувствовать;
- нужен воспроизводимый артефакт: Seed — это версионируемый файл, его можно
  положить в репозиторий и прогнать заново через полгода;
- застряли: два одинаковых фикса подряд не сработали → `unstuck`.

**Не стоит:**
- простой вопрос или однострочная правка — накладные расходы конвейера
  больше самой работы;
- Seed уже есть и валиден — тогда сразу `run`, интервью не нужно;
- задача, где критерии приёмки принципиально невыразимы («сделай красиво») —
  гейт не пройдёт, и правильно.

---

## 6. Диагностика

| Симптом | Причина / что делать |
|---|---|
| Инструментов `ouroboros_*` нет вообще | нет `uv` на PATH. В dsh это **тихий** сбой из-за `failOnStartupError: false` |
| Инструментов нет в Claude Code | `/mcp` → статус сервера; `claude plugin list` |
| Seed не генерируется | `ambiguity_score > 0.2`. Отвечай конкретнее или `force: true` (score останется в метаданных) |
| Стадия 1 ничего не проверила | нет `.ouroboros/mechanical.toml` и движок не смог его вывести. Напиши файл руками |
| В dsh плагин «установлен», но не работает | поставлен в базовый профиль, а работает пиннованный `web-<branch>` |
| Сервер упал и не встаёт | в `0.0.1-rc.1` нет авто-recovery — перезагрузи плагин или dsh |
| Оценка нестабильная от прогона к прогону | AC сформулированы неизмеримо; переписывай их, а не крути пороги |
| Job висит | `ouroboros_job_status`, затем `ouroboros_cancel_job` |

Полезные вызовы:

```
ouroboros_ac_tree_hud(session_id)      # живое дерево критериев
ouroboros_ac_dashboard(lineage_id)     # матрица AC × поколение, видно flaky
ouroboros_lineage_status(lineage_id)   # где эволюция, есть ли сходимость
ouroboros_measure_drift(...)           # насколько уехали от цели
ouroboros_project_status()             # все прогоны по проекту
```

---

## Источники

- `~/.claude/plugins/cache/ouroboros/ouroboros/0.53.0/.mcp.json` — запуск сервера в CC
- `~/.claude/plugins/cache/ouroboros/ouroboros/0.53.0/examples/dummy_seed.yaml` — форма Seed
- `$DSH_HOME/profiles/<профиль>/node_modules/dsh-ouroboros/README.md` — бандл dsh, env-таблица, allowlist
- `~/.ouroboros/config.yaml` — конфиг движка
- <https://github.com/Q00/ouroboros> — апстрим
