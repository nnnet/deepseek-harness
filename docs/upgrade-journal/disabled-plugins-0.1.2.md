# Plugins Disabled or Excluded on pin/dsh-v0.1.2-rc.1

**Дата:** 2026-09-05
**Активная ветка:** `pin/dsh-v0.1.2-rc.1` (commit `a66e470204`)
**Назначение:** единый реестр всех плагинов, которые **не работают** на 0.1.2-rc.1, и почему. Использовать как чек-лист при следующем апгрейде, при возврате на 0.1.1-rc.2, и при обсуждении upstream-багов.

---

## Категория A: исключены из `web/package.json#bundles`

**Файл:** `~/.dsh/profiles/web/package.json`

Удаление из `bundles` означает, что плагин **не устанавливается** в `web/node_modules` как bundle, host-loader не пытается его импортировать, и в `__DSH_BOOT__` его нет. Это самый «глубокий» disable.

### A1. `dsh-rlm-mode@^0.1.6` → исключён

- **Где:** `web/package.json#dependencies` (зависимость остаётся, чтобы вернуть в bundles), `web/package.json#dsh.profile.bundles` (удалено).
- **Причина:** импортирует `CallId` из `@deepseek-ai/dsh-llm`. На 0.1.2+ `dsh-llm` экспортирует `ToolCallId`, `CallId` удалён. Плагин не работает с `ToolCallId`-овым dsh-llm.
- **Что нужно для возврата:** upstream-версия `dsh-rlm-mode` с импортом `ToolCallId`. npm-published `0.2.0` помечен `deprecated "published in error — superseded by 0.1.5, do not use"` (по факту это откат). Реального 0.2.x с `ToolCallId` не существует на момент апгрейда.
- **Влияние:** RLM Mode пресет (`rlm-mode`) не монтируется. Пресет `local-fast` в `~/.dsh/.agent-presets/local-fast/agent.cordis.yml` НЕ использует `dashr-kernel` (проверено: 8 disabled `tool-*` строк, без `rlmRuntime`).
- **Серьёзность:** высокая для пользователей RLM Mode, **никакая** для local-fast.

### A2. `dsh_plugin_ad@0.3.0` → исключён

- **Где:** `web/package.json#dependencies` (link, остаётся), `web/package.json#dsh.profile.bundles` (удалено).
- **Причина:** импортирует `installSettingsSection, settingsNamespace` из `@deepseek-ai/dsh-settings`. На 0.1.2+ эти API удалены, остался `SettingsProvider` (abstract class).
- **Что нужно для возврата:** переписать плагин под `SettingsProvider` API. Это **нетривиальная** работа, потому что `installSettingsSection` инкапсулировал (ctx, namespace, schema, defaults, {setSource, onChange, validate}), а `SettingsProvider` — это абстрактный `Service` с методами `load, save, describe` и регистрацией namespace'ов через `ctx.settings.register()`.
- **Влияние:** рекламный виджет в sidebar не показывается. Виджет не критичен для функционала dsh.
- **Серьёзность:** низкая для core-функционала dsh.

---

## Категория B: `disabled: true` в `cordis.patch.yml` (id-level, для sub-bundles от @linxin666/dsh-web-all)

**Файл:** `~/.dsh/profiles/web/cordis.patch.yml`

`disabled: true` исключает entry из host-дерева (`assertEntriesLoaded` пропускает) **И** из client-`__DSH_BOOT__` (если `id` совпадает). Применимо только к sub-bundle insert'ам (т.е. id'ам, которые `@linxin666/dsh-web-all` создаёт через `insert:` в своём `cordis.patch.yml`). У этих id namespace `web-ui-*`, НЕ `@linxin666/*`.

### B1. `web-ui-doctor` (id `dsh-doctor`)

- **Причина host-side:** `lib/index.js` импортирует `installSettingsSection` из `@deepseek-ai/dsh-settings` — удалено в 0.1.2.
- **Причина client-side:** `lib/client.js` импортирует `@deepseek-ai/dsh-client-runtime/client` — удалено в 0.1.2.
- **Что нужно для возврата:** upstream-версия `dsh-doctor` под `SettingsProvider` API и под новый `dsh-client-store`.
- **Влияние:** "Doctor" панель для проверки целостности профиля не показывается.

### B2. `web-ui-skin-center` (id `dsh-client-ui-skin-center`)

- **Причина host-side:** импорт `installSettingsSection`.
- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Что нужно для возврата:** upstream-обновление `@linxin666/dsh-client-ui-skin-center`.
- **Влияние:** UI выбора тем/обоев не показывается.

### B3. `web-ui-task-board` (id `dsh-client-ui-task-board`)

- **Причина host-side:** `lib/index.js` ждёт `apiProxy` service от `@deepseek-ai/dsh-host-apiproxy`. Этот пакет удалён в 0.1.2.
- **Что нужно для возврата:** upstream-обновление `@linxin666/dsh-client-ui-task-board` под новый API gateway.
- **Влияние:** таск-менеджер не работает.

### B4. `web-ui-remote-web-ui` (id `dsh-remote-web-ui`)

- **Причина host-side:** ждёт `apiProxy` service.
- **Что нужно для возврата:** upstream-обновление `@linxin666/dsh-remote-web-ui`.
- **Влияние:** удалённый web-UI не доступен (для локального использования — не критично).

### B5. `web-ui-pet` (id `dsh-pet`)

- **Причина client-side:** `lib/client.js` импортирует `@deepseek-ai/dsh-client-runtime/client` — удалено в 0.1.2.
- **Что нужно для возврата:** upstream-версия `@linxin666/dsh-pet` под `dsh-client-store`.
- **Влияние:** виртуальный питомец в углу не показывается (UI-фича, не функциональная).

### B6. `web-ui-ssh` (id `dsh-ssh`)

- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Влияние:** SSH-панель в UI не показывается. У нас нет SSH-использования в dsh — низкое влияние.

### B7. `web-ui-describe-image` (id `dsh-tool-describe-image`)

- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Влияние:** vision-модели через UI не вызываются. Я использовал LM Studio text-only — низкое влияние.

### B8. `web-ui-desktop-launcher` (id `dsh-desktop-launcher`)

- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Влияние:** desktop-launcher в UI не показывается. Локально dsh web — низкое влияние.

### B9. `web-ui-market` (id `dsh-market`)

- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Влияние:** маркет плагинов (marketplace) в UI не показывается. У нас уже всё установлено — низкое влияние.

### B10. `web-ui-dsh-aionui-panel` (id `dsh-aionui-panel`)

- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Влияние:** AionUI панель не показывается. Не используем — низкое влияние.

### B11. `web-ui-settings` (id `dsh-client-ui-web-ui-settings`)

- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Влияние:** **среднее**. Эта панель отвечала за настройки плагинов линкшина (включая skin-center, doctor). С её отключением некоторые настройки в Settings UI не показываются. Сама `dsh-client-ui-settings` (стандартная) работает.

### B12. `web-ui-chat-recovery` (id `dsh-chat-recovery`)

- **Причина client-side:** импорт `dsh-client-runtime/client`.
- **Влияние:** восстановление чат-сессий через UI не работает. Используем SQLite-сессии — низкое влияние.

---

## Категория C: `disabled: true` (без изменений с 0.1.1, для полноты)

### C1. `deepresearch`

- **Причина:** функциональное отключение (не нужен), не связано с 0.1.2.

### C2. `mcp-ouroboros`

- **Причина:** функциональное отключение (ouroboros вынесен в `rlm-ouroboros` пресет). На 0.1.2 не тестировал, не подтверждено работоспособность.

### C3. `browser`, `browser-electron`, `tool-browser`

- **Причина:** функциональное отключение (не нужен).

---

## Категория D: shim обходные пути

**Файл:** `~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-settings/lib/index.js` (60 строк).

**Что это:** ESM-модуль, экспортирующий 0.1.x-совместимые API как noop:
- `installSettingsSection(ctx, ns, schema, defaults, opts)` — сохраняет defaults в `ctx.set()`, вызывает `opts.setSource(() => current)`, возвращает disposer.
- `settingsNamespace(name)` — возвращает `{__dsh_settings_namespace: name}`.
- `SettingsProvider` — заглушка (abstract class).
- `redactSecrets(value)` — recursive redact для строк с подозрительными именами полей.

**Симлинк:** `apps/cli/node_modules/@deepseek-ai/dsh-settings` → `~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-settings/`. **Без этого симлинка** loader не подхватывает shim (он резолвит от `apps/cli/...`, не от `web/`).

**Sed-патчи:** 8 файлов в `dsh_plugins/dsh-web/packages/*/lib/index.js` (где `import` строки заменены на абсолютный путь к shim). Файлы:
- `dsh-aionui-panel/lib/index.js`
- `dsh-chat-recovery/lib/index.js`
- `dsh-desktop-launcher/lib/index.js`
- `dsh-doctor/lib/index.js`
- `dsh-liangshen/lib/index.js`
- `dsh-market/lib/index.js`
- `dsh-remote-web-ui/lib/index.js`
- `dsh-ssh/lib/index.js`
- `dsh-task-board/lib/index.js`
- `dsh-tool-describe-image/lib/index.js`
- `dsh-web-settings/lib/index.js`
- `skins/skin-center/lib/index.js`

**Ограничения shim:**
- Плагины **не персистят** настройки в новый `ctx.settings` (SettingsProvider). UI-настройки не работают для отключённых плагинов.
- `SettingsProvider` в shim — заглушка. Любой код, наследующийся от него, получит abstract method error.
- При следующем `pnpm install` в `dsh_plugins/dsh-web/` **патчи перезапишутся**. Нужно пересобрать `dsh_plugins/dsh-web` с исправленным `tsdown` preset ИЛИ добавить в upstream PR с фиксом.

---

## Категория E: плагины, которые работают (для полноты)

Чтобы видеть контраст — на 0.1.2-rc.1 продолжают работать:

| Плагин | Версия | Почему |
|---|---|---|
| `relay-dsh-plugin-claude` | 0.2.2 | использует `Reflect.get(llm, "ToolCallId") ?? Reflect.get(llm, "CallId")` |
| `relay-dsh-plugin-codex` | 0.2.2 | то же |
| `dshmarket` | 1.44.0 | собственный shim, fallback на noop |
| `dsh-pilot` | 0.7.1 (GitHub) | bundle-only, не импортирует `dsh-llm` напрямую |
| `dsh-ouroboros` | 0.1.0 (GitHub) | bundle-only, `mcp-client` инжектится (но disabled) |
| `@deepseek-ai/dsh-deepresearch` | 0.2.2 (GitHub) | standalone |
| `@dsh-external/workflow` | 0.1.2 (GitHub) | standalone |
| `@tt-a1i/archify-dsh` | 0.1.0 | standalone |
| `@wxg-prc-cpg/dsh-weknora` | 0.1.0 | standalone |
| `@openviking/dsh-memory-plugin` | 0.2.1 | несовместимость с 0.1.2 возможна, но не тестировали |
| `@vectorize-io/hindsight-coding-agents` | 0.4.3 | несовместимость с 0.1.2 возможна |
| `dsh-builtin-browser` | 0.1.21 | disabled в profile, не тестировали |
| `relay-dsh-plugin-session-import` | (npm latest) | standalone, не требует `dsh-llm` |
| `dsh-better-sidebar` | 0.15.2 | standalone, не тестировали |
| `@mlgbnb/dsh-archive-manager` | (npm) | standalone |

Из linxin'а остаются активными (только client-сторона, host не импортирует удалённое):
- `@linxin666/dsh-web-all` (агрегатор, без client-require `dsh-client-runtime/client`)
- `@linxin666/dsh-client-ui-plugin-manager` (Plugin Manager UI)
- `@linxin666/dsh-client-ui-git-graph` (Git graph UI)
- `@linxin666/dsh-client-ui-skill-explorer` (Skill explorer UI)

---

## Сводная таблица по влиянию

| Уровень | Плагинов | Влияние на работу | Когда вернуть |
|---|---|---|---|
| **Core функционал dsh** | 0 отключено | ничего не теряем | n/a |
| **UI features (полезные)** | 4-5 отключено (task-board, remote-web-ui, doctor, skin-center, settings) | теряем UI для настроек плагинов | upstream-обновления |
| **UI features (нишевые)** | 8-9 отключено (pet, ssh, aionui, chat-recovery, describe-image, market, desktop-launcher, etc.) | теряем неиспользуемый UI | upstream-обновления |
| **Specialty** | 2 исключено (dsh-rlm-mode, dsh_plugin_ad) | теряем RLM Mode + рекламный виджет | ждать новых версий или переписать |

**Bottom line:** dsh на 0.1.2-rc.1 работает. Полноценный возврат к 0.1.1.x совместимости — задача для **upstream-авторов плагинов**, не наша.

---

## Чек-лист «вернуть плагин X на 0.1.2»

Для каждого плагина в категориях A, B:

1. **Проверить npm/GitHub на новую версию.**
   - Для linxin-плагинов: `npm view @linxin666/<pkg> version` (текущий latest = 0.3.16 для web-all, для остальных — 0.3.3).
   - Для dsh-rlm-mode: искать `ToolCallId` в новых версиях на GitHub Q00.
   - Для dsh_plugin_ad: это локальный плагин, не ищем — пишем сами.
2. **Проверить peer-deps.** Поле `peerDependencies` в `package.json` плагина.
3. **Поднять версию в `web/package.json#dependencies`.**
4. **pnpm install --no-frozen-lockfile в `web/`.**
5. **Проверить `web/node_modules/<pkg>/lib/index.js`** на `installSettingsSection` или `CallId`:
   - Если остались — shim не сработает, нужно ждать следующей версии.
6. **Проверить `web/node_modules/<pkg>/lib/client.js`** на `dsh-client-runtime/client`:
   - Если остался — ждать следующей версии или модифицировать upstream.
7. **Восстановить `disabled: true` → удалить строку в `cordis.patch.yml`.**
8. **Восстановить bundle-level** → добавить id обратно в `web/package.json#dsh.profile.bundles`.
9. **Перезапустить dsh, проверить `__DSH_BOOT__`** — id должен появиться.
10. **Открыть в браузере, проверить, что нет ошибок** `HARNESS Failed to load plugins` для этого id.

---

## Файлы, на которые опирается этот реестр

- `~/.dsh/profiles/web/package.json` — текущая версия 0.1.2-конфигурации
- `~/.dsh/profiles/web/cordis.patch.yml` — disabled-список
- `~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-settings/lib/index.js` — shim
- `~/.dsh/profiles/web/package.json.0.1.1` — backup для возврата
- `plans/260905-1830-plugin-upgrade-roadmap/03-launched-on-0.1.2-rc.1.md` — отчёт о запуске
- `docs/upgrade-journal/0.1.1-to-0.1.2.md` — полное руководство
