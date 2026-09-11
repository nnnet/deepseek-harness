# Disabled 12 linxin plugins on 0.1.2-rc.1 (260905-19:21)

## Проблема

На 0.1.2-rc.1 в shell `packages/client/web/src/platform.ts` `PRELOADED_CLIENT_EXTERNALS = []` (пуст), а в `seed.ts` вместо `@deepseek-ai/dsh-client-runtime/client` — `@deepseek-ai/dsh-client-store`. Пакет `packages/client/runtime` удалён из monorepo.

9 линксиновских плагинов в `lib/client.js` делают `require("@deepseek-ai/dsh-client-runtime/client")` — в 0.1.2 этого external'а в seed-table нет, и они падают на client:

```
HARNESS Failed to load plugins
failed to import loader entry 2d80c672 (@linxin666/dsh-client-ui-web-ui-settings):
client-modules: require("@deepseek-ai/dsh-client-runtime/client") missed the module table
```

## Решение

Без правки репозитория (по решению пользователя в этой сессии): **отключил 9 проблемных плагинов** в `~/.dsh/profiles/web/cordis.patch.yml` через `disabled: true`.

Правильные id (из `dsh_plugins/dsh-web/packages/dsh-web-all/cordis.patch.yml` — namespace `web-ui-*`, НЕ `@linxin666/dsh-*`):

```
- id: web-ui-pet                    disabled: true
- id: web-ui-ssh                    disabled: true
- id: web-ui-describe-image         disabled: true
- id: web-ui-desktop-launcher       disabled: true
- id: web-ui-market                 disabled: true
- id: web-ui-dsh-aionui-panel       disabled: true
- id: web-ui-settings               disabled: true
- id: web-ui-chat-recovery          disabled: true
- id: web-ui-doctor                 disabled: true   (ранее)
- id: web-ui-skin-center            disabled: true   (ранее)
- id: web-ui-task-board             disabled: true   (ранее, ждал apiProxy)
- id: web-ui-remote-web-ui          disabled: true   (ранее, ждал apiProxy)
```

Плюс из `web/package.json#bundles` убраны: `dsh-rlm-mode`, `dsh_plugin_ad`.

## Что работает на 0.1.2-rc.1

**Плагинов в `__DSH_BOOT__`: 57** (было 60).

**Линксиновские оставшиеся (4) — без `dsh-client-runtime/client` в client.js**:
- `@linxin666/dsh-web-all` (агрегатор)
- `@linxin666/dsh-client-ui-plugin-manager`
- `@linxin666/dsh-client-ui-git-graph`
- `@linxin666/dsh-client-ui-skill-explorer`

Остальные 56 — базовые dsh-плагины (cordis, runtime, llm, session, market, pilot, relay-*, и т.д.).

## URL и токен

```
http://127.0.0.1:3080/?token=1gAgFGz17MTPV0Fw0kifW5iw2gzmSviC8uj7yjcATSU
```

- Server: `HTTP/1.1 200 OK` с cookie.
- Cookie: `dsh-auth-VPhEEcLKeqRDBoBalzN2Nm7CnfxKhLE00pKIDWxt1sw` (после редиректа с `?token=`).

## Сторона, которую я не тестировал

**Браузер** — у меня нет интерактивного доступа. Я проверил:
- HTTP отдаёт HTML с title `DSH Local Build`.
- Cookie auth работает (`?token=` → 303 → cookie → 200).
- Все client.js доступны по `??<url>&rev=...` (формат 0.1.2).
- `__DSH_BOOT__` корректный, 57 entries.
- `2d80c672` (старая ошибка) **ушла**.

Что может **упасть в браузере**, чего я не вижу:
- HMR/ws errors.
- Re-export цепочки, которых я не проверил.
