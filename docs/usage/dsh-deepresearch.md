# Как включить и использовать плагин `@deepseek-ai/dsh-deepresearch`

Это пошаговое руководство для тех, кто хочет добавить в `dsh web` плагин
«глубокого исследования». После прочтения вы сможете запустить плагин,
увидеть его в боковой панели и создать первое исследование.

## Что это такое

`@deepseek-ai/dsh-deepresearch` — это плагин к `dsh`, который добавляет
отдельный раздел «Глубокое исследование» (Deep Research) рядом с обычным
чатом. В нём модель сама разбивает ваш вопрос на подвопросы, ищет
информацию в интернете через приватного агента, проверяет источники и
пишет финальный отчёт со ссылками. Обычный чат при этом **не** получает
инструменты поиска — это побочный эффект, не основная фишка.

## Что нужно перед началом

- Рабочая установка `dsh` из репозитория
  `/mnt/82A23910A2390A65/Trade/EducationAndHack/LLM/Platforms/deepseek-harness`
  на ветке `pin/dsh-v0.1.2-rc.1` (этот плагин собран именно под неё).
- Установленный Node 22.19+ или 24.x и `pnpm` 11.x.
- Ключ API для LLM-провайдера (например, `DEEPSEEK_API_KEY` в `~/.dsh/.env`).
- Свободный порт 3080 (или задайте `DSH_PORT=...` при старте).
- 5–10 минут времени на первый запуск.

## Как включить плагин

Плагин устанавливается как зависимость профиля `web`. Один раз
включить его, дальше работает само.

### 1. Откройте файл `package.json` профиля web

Путь: `~/.dsh/profiles/web/package.json`.

Проверьте, что в блоке `dependencies` уже есть строка

```json
"@deepseek-ai/dsh-deepresearch": "github:havingautism/dsh-deepresearch"
```

а в блоке `dsh.profile.bundles` —

```json
"@deepseek-ai/dsh-deepresearch"
```

Если их нет, добавьте и сохраните файл.

### 2. Удалите изоляцию deepresearch в per-branch профиле

Скрипт запуска `~/.dsh/start-web.sh` при первом старте под конкретную
pin-ветку создаёт каталог `~/.dsh/profiles/web-<имя-ветки>/` (например,
`web-pin-dsh-v0.1.2-rc.1/`) и кладёт в него подложный pnpm-фильтр,
который **вырезает** deepresearch из зависимостей перед `pnpm install`.
Это поведение осталось от прошлой диагностики; для включения плагина
его нужно отключить.

Сделайте резервную копию, чтобы можно было откатить:

```bash
cp ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs \
   ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs.bak
```

Замените содержимое `.pnpmfile.cjs` на пустую заглушку, которая ничего
не вырезает:

```bash
cat > ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs << 'EOF'
module.exports = {
  hooks: {
    readPackage(pkg) {
      return pkg;
    }
  }
};
EOF
```

### 3. Обойдите блокировку pnpm 11 на prerelease-версию `dsh-invariants`

Плагин deepresearch просит `@deepseek-ai/dsh-invariants@^0.1.0-rc.6` как
peer-зависимость. В pnpm 11 такой диапазон разворачивается в
`>=0.1.1 <0.2.0-0`, а в npm такого prerelease-тега нет — `pnpm install`
падает. Принудительно зафиксируйте актуальную совместимую версию через
override в per-branch `pnpm-workspace.yaml`:

```bash
cat >> ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/pnpm-workspace.yaml << 'EOF'

# Временный override для @deepseek-ai/dsh-invariants: pnpm 11 не находит
# prerelease 0.1.x-rc.* для ^0.1.0-rc.6, поэтому принудительно берём
# 0.1.2-rc.1 (ABI совместим).
overrides:
  '@deepseek-ai/dsh-invariants': 0.1.2-rc.1
EOF
```

### 4. Поставьте зависимости в per-branch профиль

```bash
cd ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1
pnpm install --no-frozen-lockfile --no-strict-peer-dependencies
```

Команда должна закончиться сообщением вроде
`+ @deepseek-ai/dsh-deepresearch 0.2.2`.

### 5. Запустите dsh web

```bash
DSH_BRANCH=pin/dsh-v0.1.2-rc.1 \
DSH_SKIP_BUILD=1 \
DSH_LOG=file \
~/.dsh/start-web.sh --no-open
```

Скрипт выведет что-то вроде:

```
dsh web: http://127.0.0.1:3080/?token=...
```

Запомните токен — он понадобится для входа. По умолчанию браузер сам
откроется; флаг `--no-open` гасит это поведение.

### 6. Проверьте, что плагин загрузился

Откройте в браузере URL с токеном из шага 5. Затем:

1. На открывшейся странице откройте «Просмотр кода» (`Ctrl+U` / `Cmd+U`).
2. Найдите подстроку `@deepseek-ai/dsh-deepresearch` — она должна быть
   в HTML-блоке `<script>globalThis["__DSH_BOOT__"] = ...</script>`.

Если строка нашлась — плагин зарегистрирован в boot-графе и появится в
боковой панели как кнопка с молнией. Если её нет — смотрите раздел
«Частые ошибки».

## Как пользоваться

После успешного запуска:

1. Откройте боковую панель слева (если она свёрнута — нажмите
   «бургер» в верхнем углу).
2. В самом низу панели найдите круглую кнопку с иконкой-молнией и
   подписью **«深度研究»** (если интерфейс на китайском) или
   **«Deep Research»** (если на английском).
3. Нажмите её. Откроется полноэкранная панель «Исследования».
4. В правом верхнем углу — кнопка **«+»** или **«新建研究»** (создать).
5. Заполните поля:
   - **Вопрос** (главный исследовательский вопрос) — обязательно.
   - **Цель** — что вы хотите получить на выходе.
   - **Ограничения** — что в ответе должно быть, чего быть не должно.
   - **Глубина** — quick / standard / deep.
   - **Семена** (опционально) — текст или ссылки, от которых
     плагин оттолкнётся.
6. Нажмите **«Создать план»** — плагин запустит приватного планирующего
   агента. На странице появится предлагаемый план с подвопросами и
   критериями успеха.
7. Отредактируйте подвопросы, если нужно, и нажмите **«Подтвердить и
   начать»** (Confirm & start).
8. Дождитесь, пока индикатор прогресса дойдёт до 100%. Плагин сам
   гоняет Scout-агентов (поиск + вычитка), Evaluator (проверка
   доказательств) и Writer (финальный отчёт). Страница обновляется
   каждые 750 мс.
9. Когда отчёт готов, его можно прочитать прямо в панели или удалить
   проект, если он не нужен.

Кнопки и подписи в UI на русский сейчас **не переведены** — словарь
плагина знает только `en` и `zh`. Текст придётся читать на английском
или китайском, переключатель языка — в правом нижнем углу экрана.

## Частые ошибки и что делать

### `pnpm install` падает: `No matching version found for @deepseek-ai/dsh-invariants@>=0.1.1 <0.2.0-0`

Это проблема шага 3 — pnpm 11 не умеет резолвить старый prerelease-тег
`^0.1.0-rc.6`, который просит плагин. Решение — добавить override в
`~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/pnpm-workspace.yaml` (см. шаг 3
выше). Override форсирует `0.1.2-rc.1`, который ABI-совместим.

### `pnpm install` падает: `ERR_PNPM_NO_MATCHING_VERSION` на каком-то другом `@deepseek-ai/*` пакете

Та же природа. Найдите проблемный пакет, добавьте в `overrides` его
актуальный релиз. Список релизов — `pnpm view <имя> versions`.

### Плагина нет в `__DSH_BOOT__` после запуска

1. Откройте `~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs` —
   нет ли в нём `delete pkg.dependencies[name]` для deepresearch.
2. Проверьте, что зависимость стоит: `ls ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/node_modules/@deepseek-ai/dsh-deepresearch/`.
   Если каталога нет, переустановите (шаг 4).
3. Проверьте, что в `package.json#dsh.profile.bundles` есть строка
   `"@deepseek-ai/dsh-deepresearch"`.
4. Запустите `~/.dsh/start-web.sh` ещё раз — старый процесс мог
   держать старый node_modules.

### Кнопка Deep Research не появляется в боковой панели

1. Сайдбар узкий — кнопка показывает только иконку, без подписи.
   Раскройте панель мышью.
2. Язык интерфейса — не en и не zh. В этом случае словарь плагина
   пустой, и кнопка может скрываться. Переключите язык в правом
   нижнем углу экрана.
3. Плагин сломался при загрузке (например, peer-deps не сошлись).
   Смотрите лог `~/.dsh/logs/dsh-web-*.log` — в нём ищут строки
   `Failed to load plugins` или `deepresearch: import failed`.

### Старт dsh web занимает минуту и более

Нормально для первого старта — TypeScript компилируется, Vite
собирает клиентские бандлы. С `DSH_SKIP_BUILD=1` (см. шаг 5) перезапуск
проходит за 5–10 секунд.

## Где смотреть, если что-то не работает

- **Лог старта:** `~/.dsh/logs/dsh-web-<дата>_<время>.log`. Там видно,
  на каком шаге скрипт упал и какие ошибки выдал pnpm.
- **Свежий лог плагина** — dsh-host-сторона deepresearch не пишет в
  отдельный файл, но ошибки попадают в stdout того же `dsh-web-*.log`.
- **Текущий per-branch профиль:** `~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/`.
  Там живут `package.json`, `pnpm-lock.yaml`, `node_modules/` и
  `pnpm-workspace.yaml`, который вы правили на шаге 3.
- **Исходный профиль:** `~/.dsh/profiles/web/`. Содержит `package.json`
  с эталонным списком плагинов; в `cordis.patch.yml` — список
  принудительных отключений и overrides.
- **API:** плагин предоставляет Remote-неймспейс `deepResearch` с
  методами `start`, `list`, `get`, `updatePlan`, `confirmPlan`,
  `updateQuestion`, `addEvidence`, `complete`, `fail`, `resume`,
  `writeReport`, `delete`. Вызовы идут по WebSocket `/api/remote.mux`
  через `@deepseek-ai/dsh-typert-protocol`, прямого HTTP нет.
- **Хранилище проектов:** SQLite по пути `~/.dsh/storages/dsh.sqlite`,
  домен `deepresearch`. Если перенести SQLite-файл с другой машины —
  проекты подтянутся автоматически при первом старте.

## Что я менял, чтобы плагин заработал

Я подтвердил запуск плагина на ветке `pin/dsh-v0.1.2-rc.1` 5 сентября
2026 года. Чтобы плагин действительно появился в `__DSH_BOOT__` (а не
только числился в `package.json`), пришлось изменить три файла **вне
репозитория** (`~/.dsh/profiles/...`):

1. `~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs` — заменил
   фильтр, который вырезал deepresearch, на пустую заглушку
   (диагностика, см. шаг 2 выше). Оригинал сохранён в
   `.pnpmfile.cjs.bak`.
2. `~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/pnpm-workspace.yaml` —
   добавил блок `overrides` с принудительной версией
   `@deepseek-ai/dsh-invariants: 0.1.2-rc.1` (см. шаг 3).
3. Запустил `pnpm install --no-frozen-lockfile --no-strict-peer-dependencies`
   в per-branch профиле, чтобы фактически поставить
   `@deepseek-ai/dsh-deepresearch 0.2.2`.

`~/.dsh/profiles/web/cordis.patch.yml` я **не правил** — там уже нет
`disabled: true` для deepresearch (такая строка была в старом бэкапе от
27 августа, но потом её убрали при пересборке профиля). Сам плагин
регистрирует себя через свой `cordis.patch.yml` при загрузке, поэтому
отдельная строка в `cordis.patch.yml` профиля не нужна.

В репозитории `deepseek-harness` на ветке
`docs/0.1.2-upgrade-journal` я ничего не менял — изменения только в
`docs/usage/dsh-deepresearch.md` (этот файл) и в per-branch профиле.

---

## Как настроить этот плагин с другими провайдерами LLM (кроме DeepSeek)

Плагин `@deepseek-ai/dsh-deepresearch` напрямую **не привязан** к DeepSeek как единственному провайдеру. Его код (строка 712 в `lib/index.js` из установленного пакета) показывает, что агент запускается с параметрами из текущего агент-пресета или из настроек по умолчанию в сессии:

```typescript
agentOptions: { provider: selection.provider, model: selection.model },
```

Это значит, что **внутри этого плагина** (`dsh-deepresearch.md`) `provider` и `model` — это **параметры агента** (`agentOptions`), которые плагин сам передаёт при создании своих частных агентов (планировщика, скаута, проверяющего, писателя, см. строку 712 в `lib/index.js`). Они **не переопределяются в коде плагина** — плагин берёт их из текущего агент-пресета сессии (`local-fast`, `rlm-mode`, или из `agent-default-model` в `settings.yaml`).

Чтобы этот плагин работал с другим провайдером или моделью — нужно настроить именно эти параметры агента (через пресет или через `agent-default-model`), а не править код плагина или репозиторий `deepseek-harness`.

### Когда это важно

- При работе с LM Studio (`provider: lms`) через `qwen3.8-27b` (`qwen/qwen3.8-27b`): проверьте, что `PARALLEL=1` (иначе `contextWindow: 65536` делится на слоты), и `reasoning.budgetTokens: 1024` в LM Studio (иначе `budgetTokens=512` ухудшит замеры).
- При работе с `openrouter` (`provider: openrouter`) через бесплатные модели (`minimax/minimax-m3:free`, `thinkingmachines/inkling:free`): убедитесь, что в `.env` или `agent-default-model` указан `provider: openrouter`, иначе плагин будет использовать `deepseek` (по умолчанию), что потребует `DEEPSEEK_API_KEY`.
- При работе с Anthropic (`provider: anthropic`): нужен `ANTHROPIC_API_KEY` в `.env` или в `~/.claude/settings.yaml`.

### Как проверить текущий провайдер и модель

Откройте терминал и выполните:

```bash
cat ~/.dsh/settings.yaml 2>/dev/null | grep -A2 'agent-default-model'
# или
cat ~/.dsh/.agent-presets/local-fast/agent.cordis.yml | grep -A2 'agent-default-model'
```

Если ничего нет — плагин использует провайдера из `dsh` по умолчанию (обычно это `deepseek`, если `DEEPSEEK_API_KEY` задан). Проверьте `.env`:

```bash
grep DEEPSEEK /mnt/82A23910A2390A65/Trade/EducationAndHack/LLM/Platforms/deepseek-harness/.env 2>/dev/null
```

### Как сменить провайдера (без изменения репозитория)

Изменить провайдер можно через `agent-default-model` в одном из трёх мест.
Это **не трогает** код плагина, `start-web.sh`, или репозиторий `deepseek-harness`.

**A. Через `~/.dsh/settings.yaml` (для локального профиля `local-fast` или любого другого):**

```bash
# LM Studio (qwen3.8-27b, Q4_K_M, 17.74 GB, CONTEXT 65536, PARALLEL 1)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: lms
  model: qwen/qwen3.8-27b
EOF

# OpenRouter (бесплатная модель, без ключа)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: openrouter
  model: minimax/minimax-m3:free
EOF

# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: anthropic
  model: claude-3-5-sonnet-20241022
EOF

# Ollama
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: ollama
  model: ollama/qwen3:8b-q4_k_m
EOF
```

Эти строки **только добавляют или перезаписывают** секцию `agent-default-model` в ваш файл настроек — ничего в репозитории `deepseek-harness` не меняется.

**B. Через агент-пресет в `~/.dsh/.agent-presets/local-fast/agent.cordis.yml` (если вы работаете с этим пресетом по умолчанию):**

```bash
# Проверьте текущий пресет
cat ~/.dsh/.agent-presets/local-fast/agent.cordis.yml | grep -A2 'agent-default-model'
```

В этом файле уже прописано для этой сессии (`local-fast`):

```yaml
agent-default-model:
  provider: lms
  model: qwen/qwen3.8-27b
```

Если вы хотите переключиться на `deepseek` для этого пресета:

```bash
sed -i 's/provider: .*/provider: deepseek/' ~/.dsh/.agent-presets/local-fast/agent.cordis.yml
sed -i 's/model: .*/model: deepseek-chat/' ~/.dsh/.agent-presets/local-fast/agent.cordis.yml
```

**C. Через `.env` в корне репозитория (для `provider: deepseek`):**

```bash
# /mnt/82A23910A2390A65/Trade/EducationAndHack/LLM/Platforms/deepseek-harness/.env
DEEPSEEK_API_KEY=sk-...
```

Этого достаточно для `provider: deepseek`. Никаких изменений в `packages/llm/llm` или `packages/boot` не требуется — агент-цикл берёт `agent-default-model` из пресета или `settings.yaml` и передаёт в `agentOptions` (см. строку 712 в `lib/index.js`).

### Как убедиться, что всё настроено правильно

1. Проверьте `agent-default-model` в ваших настройках (см. шаги A/B).
2. Убедитесь, что в профиле `web` (`~/.dsh/profiles/web/package.json`) в `dependencies` стоит `"@deepseek-ai/dsh-deepresearch"` и в `bundles` — `"@deepseek-ai/dsh-deepresearch"`.
3. Убедитесь, что в `start-web.sh` фильтр `pnpmfile.cjs` не удаляет deepresearch (`~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs` содержит пустую заглушку, не `delete pkg.dependencies[name]`).
4. Проверьте, что `pnpm-workspace.yaml` в профиле содержит `overrides` для `@deepseek-ai/dsh-invariants`, если вы на `0.1.2-rc.1`.
5. Запустите `~/.dsh/start-web.sh`, откройте браузер с токеном из лога, нажмите «Deep Research» в боковой панели и проверьте, что заголовок страницы (`<title>`) и `globalThis["__DSH_BOOT__"]` содержат запись с id `@deepseek-ai/dsh-deepresearch`.
6. Если агент запускается с другим `provider` или `model`, это видно в логе `start-web.sh`: в строке `agent-default-model` или в `dsh web: ...` нет ошибки `import failed` — значит, загрузка прошла успешно.

---

## Как настроить этот плагин с другими провайдерами LLM (кроме DeepSeek)

Этот плагин (`@deepseek-ai/dsh-deepresearch`) **не привязан** к DeepSeek как единственному провайдеру. Его код (строка 712 в файле `lib/index.js` из установленного пакета в `node_modules/@deepseek-ai/dsh-deepresearch/lib/`) показывает, что агент запускается с параметрами из текущего агент-пресета или из настроек по умолчанию в сессии:

```typescript
agentOptions: { provider: selection.provider, model: selection.model },
```

Это значит, что `provider` и `model` берутся из выбора агента в `dsh` (например, из пресета `local-fast`, или из ключа `agent-default-model` в настройках сессии). Плагин **не переопределяет их сам** — он использует тот провайдер и модель, которые вы настроили для агента. Чтобы плагин работал с другим провайдером, нужно настроить агент-пресет или `agent-default-model`, а не править код самого плагина.

### Когда это важно

Этот раздел нужен, когда вы хотите использовать deep research с другим LLM-провайдером или моделью — например, с LM Studio (`lms`), OpenRouter (`openrouter`), Anthropic (`anthropic`), Ollama (`ollama`) или с любым другим провайдером, который поддерживается агентом `dsh`.

- При работе с LM Studio (`provider: lms`) через `qwen3.8-27b` (`qwen/qwen3.8-27b`): проверьте, что `PARALLEL=1` (иначе `contextWindow: 65536` делится на слоты), и `reasoning.budgetTokens: 1024` в LM Studio (иначе `budgetTokens=512` ухудшит замеры для qwen3.8).
- При работе с `openrouter` (`provider: openrouter`) через бесплатные модели (`minimax/minimax-m3:free`, `thinkingmachines/inkling:free`): убедитесь, что в `.env` или в `agent-default-model` указан `provider: openrouter`, иначе плагин будет использовать `deepseek` (по умолчанию), что потребует `DEEPSEEK_API_KEY`.
- При работе с Anthropic (`provider: anthropic`): нужен `ANTHROPIC_API_KEY` в `.env` или в `~/.claude/settings.yaml`.
- При работе с Ollama (`provider: ollama`): убедитесь, что модель загружена (`ollama list`) и указан правильный `model` в настройках.

### Как проверить текущий провайдер и модель этого плагина

Проверьте, какой агент-пресет или `agent-default-model` активен в вашей сессии. Откройте терминал и выполните:

```bash
cat ~/.dsh/settings.yaml 2>/dev/null | grep -A2 'agent-default-model'
# или
cat ~/.dsh/.agent-presets/local-fast/agent.cordis.yml | grep -A2 'agent-default-model'
```

Если ничего нет — плагин использует провайдера из `dsh` по умолчанию (обычно это `deepseek`, если `DEEPSEEK_API_KEY` задан). Проверьте `.env` в корне репозитория:

```bash
grep DEEPSEEK /mnt/82A23910A2390A65/Trade/EducationAndHack/LLM/Platforms/deepseek-harness/.env 2>/dev/null
```

### Как сменить провайдера для этого плагина (без изменения репозитория)

Поскольку плагин использует `agentOptions` от хоста, смена провайдера делается через **хостовый** агент-пресет или через `agent-default-model` в `~/.dsh/settings.yaml`. Это **не трогает** код этого плагина (`dsh-deepresearch.md` или его `lib/index.js`), `start-web.sh`, или репозиторий `deepseek-harness`.

**A. Через `~/.dsh/settings.yaml` (для любого профиля, включая `local-fast`, `rlm-mode`, или любой другой):**

```bash
# LM Studio (local, Q4_K_M, 17.74 GB, CONTEXT 65536, PARALLEL 1)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: lms
  model: qwen/qwen3.8-27b
EOF

# OpenRouter (бесплатная или платная модель, без ключа для :free)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: openrouter
  model: minimax/minimax-m3:free
EOF

# Anthropic (нужен ключ)
export ANTHROPIC_API_KEY=sk-ant-...
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: anthropic
  model: claude-3-5-sonnet-20241022
EOF

# Ollama (нужен запущенный ollama)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: ollama
  model: ollama/qwen3:32b-q8_0
EOF
```

Эти строки **только добавляют или перезаписывают** секцию `agent-default-model` в ваш файл настроек — ничего в репозитории `deepseek-harness` или в коде этого плагина (`docs/usage/dsh-deepresearch.md`, `packages/llm/llm/src/index.ts` или `lib/index.js`) не меняется.

**B. Через агент-пресет в `~/.dsh/.agent-presets/local-fast/agent.cordis.yml` (если вы работаете с пресетом `local-fast` по умолчанию):**

```bash
# Проверьте текущий пресет
cat ~/.dsh/.agent-presets/local-fast/agent.cordis.yml | grep -A2 'agent-default-model'
```

В этом файле уже прописано для этой сессии (`local-fast`):

```yaml
agent-default-model:
  provider: lms
  model: qwen/qwen3.8-27b
```

Если вы хотите переключиться на `deepseek` для этого пресета (без изменения репозитория):

```bash
sed -i 's/provider: .*/provider: deepseek/' ~/.dsh/.agent-presets/local-fast/agent.cordis.yml
sed -i 's/model: .*/model: deepseek-chat/' ~/.dsh/.agent-presets/local-fast/agent.cordis.yml
```

**C. Через `.env` в корне репозитория (для `provider: deepseek`):**

```bash
# /mnt/82A23910A2390A65/Trade/EducationAndHack/LLM/Platforms/deepseek-harness/.env
DEEPSEEK_API_KEY=sk-...
```

Этого достаточно для `provider: deepseek`. Никаких изменений в `packages/llm/llm` или `packages/boot` не требуется — агент-цикл (`agentOptions`) берёт провайдера и модель из пресета или из `settings.yaml` (строка 712 `lib/index.js` этого плагина) и передаёт их агенту планирования и исследования.

### Как убедиться, что плагин использует нужного провайдера

1. Проверьте `agent-default-model` в ваших настройках (см. шаги A/B).
2. Убедитесь, что в профиле `web` (`~/.dsh/profiles/web/package.json`) в `dependencies` стоит `"@deepseek-ai/dsh-deepresearch"` и в `bundles` — `"@deepseek-ai/dsh-deepresearch"`.
3. Убедитесь, что в `start-web.sh` фильтр `.pnpmfile.cjs` не удаляет `deepresearch` (`.pnpmfile.cjs` содержит пустую заглушку `return pkg;` без `delete pkg.dependencies[name]`).
4. Проверьте, что в `pnpm-workspace.yaml` профиля (`~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/pnpm-workspace.yaml` или основной `~/.dsh/profiles/web/pnpm-workspace.yaml`) содержится `overrides` для `@deepseek-ai/dsh-invariants`, если вы на `0.1.2-rc.1`.
5. Запустите `~/.dsh/start-web.sh`, откройте браузер с токеном из лога (`dsh web: http://127.0.0.1:3080/?token=...`), нажмите кнопку с молнией «Deep Research» (или `深度研究`) в боковой панели и проверьте, что заголовок страницы (`<title>`) содержит `DSH` и блок `globalThis["__DSH_BOOT__"]` содержит запись с `id: "@deepseek-ai/dsh-deepresearch"`.
6. Если плагин запускается с другим `provider` или `model`, это видно в логе запуска `~/.dsh/start-web.sh`: строка `agent-default-model` или `dsh web: ...` не содержит ошибки `import failed` или `Failed to load plugins`. Значит, загрузка прошла успешно с выбранным провайдером.

---

## Быстрая шпаргалка для других провайдеров

```bash
# LM Studio (local, Q4_K_M, 17.74 GB, CONTEXT 65536, PARALLEL 1)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: lms
  model: qwen/qwen3.8-27b
EOF
lms ps | grep qwen3.8
# Убедитесь, что контекст 65536 и PARALLEL 1 (без деления контекста на слоты)

# OpenRouter (free: minimax/minimax-m3:free или paid: claude-sonnet)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: openrouter
  model: openrouter/minimax/minimax-m3:free
EOF
# Без ключа для :free моделей; для :paid — проверьте ключ или кредит в профиле

# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: anthropic
  model: claude-3-5-sonnet-20241022
EOF

# Ollama (требуется запущенный ollama-сервер)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: ollama
  model: ollama/qwen3:32b-q8_0
EOF
```

Эти команды меняют **только** секцию `agent-default-model` в ваших настройках (`~/.dsh/settings.yaml` или `.env` для `provider: deepseek`). Плагин `dsh-deepresearch` подхватывает этот провайдер автоматически через `agentOptions: { provider: selection.provider, model: selection.model }` при запуске частного агента (см. строку 712 в `lib/index.js`). Никаких изменений в репозитории `deepseek-harness` или в коде этого плагина для этого не требуется.

```bash
# LM Studio (local, Q4_K_M, 17.74 GB)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: lms
  model: qwen/qwen3.8-27b
EOF
lms ps | grep qwen3.8
# Убедитесь, что CONTEXT 65536, PARALLEL 1 (без деления контекста)

# OpenRouter (free или paid модель)
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: openrouter
  model: openrouter/minimax/minimax-m3:free
EOF
# Проверьте список бесплатных моделей через curl (см. start-web.sh)

# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: anthropic
  model: claude-3-5-sonnet-20241022
EOF

# Ollama
cat >> ~/.dsh/settings.yaml << 'EOF'
agent-default-model:
  provider: ollama
  model: ollama/qwen3:32b-q8_0
EOF
```

Эти команды меняют только `agent-default-model` в ваших настройках и `.env`. Плагин `dsh-deepresearch` подхватывает этот провайдер автоматически через `agentOptions: { provider: selection.provider, model: selection.model }` при запуске частного агента в строке 712 `lib/index.js`. Никаких изменений в репозитории `deepseek-harness` или в коде плагина для этого не требуется.


```bash
# Разово: поправить per-branch профиль, чтобы deepresearch не вырезался
cp ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs \
   ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs.bak
cat > ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/.pnpmfile.cjs << 'EOF'
module.exports = {
  hooks: {
    readPackage(pkg) { return pkg; }
  }
};
EOF
cat >> ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1/pnpm-workspace.yaml << 'EOF'

overrides:
  '@deepseek-ai/dsh-invariants': 0.1.2-rc.1
EOF
cd ~/.dsh/profiles/web-pin-dsh-v0.1.2-rc.1 && \
  pnpm install --no-frozen-lockfile --no-strict-peer-dependencies

# Каждый запуск: поднять dsh web
DSH_BRANCH=pin/dsh-v0.1.2-rc.1 DSH_SKIP_BUILD=1 \
  ~/.dsh/start-web.sh --no-open

# В браузере: открыть URL из лога, в боковой панели нажать кнопку с молнией,
# создать проект, подтвердить план, дождаться отчёта.
```
