# dsh в изоляции: Docker и Firecracker

Мануал по запуску DeepSeek Harness (`@deepseek-ai/dsh`) в контейнере или
микро-ВМ с пробросом рабочих каталогов наружу, и по переносу накопленного
состояния между хостами.

Разделы 1–8 — Docker. Разделы 9–11 — перенос состояния и Firecracker.

Проверено против checkout'а `dsh` 0.1.2-rc.1 в этом репозитории.
**Upstream не содержит Dockerfile, compose или k8s-манифестов** — всё ниже
собирается самостоятельно.

---

## 1. Что вообще нужно монтировать

### `DSH_HOME` — единственная настоящая граница состояния

Всё пользовательское состояние харнесса живёт в одном каталоге. По умолчанию
`~/.dsh`, переопределяется переменной `DSH_HOME`
(`docs/config-catalog.md:2076`).

| Путь внутри `DSH_HOME` | Что там | Терять нельзя? |
|---|---|---|
| `settings.yaml` | провайдеры, модели, роутинг, дефолты | **да** |
| `.credentials.yaml` | API-ключи (режим write-only) | **да** |
| `sessions/` | логи сессий (`session.jsonl.zstd`), resume/fork | **да** |
| `profiles/<name>/` | `package.json` + `node_modules` профиля | да (но тяжёлый) |
| `storages/` | состояние workspace и доменных плагинов | да |
| `attachments/v1/` | картинки из сообщений | да |
| `.agent-presets/` | пользовательские agent-пресеты | да |
| `mcp.json` | реестр MCP-серверов | да |
| `logs/` | логи запусков | нет |

Отдельно замечу про `profiles/`: это `node_modules` установленных плагинов,
в живой инсталляции он легко разрастается до **нескольких гигабайт**
(в текущей рабочей копии — 2.5 ГБ). Держать его в bind-mount на медленной
или сетевой ФС — плохая идея; лучше именованный volume.

### Рабочий каталог агента

Второй монтируемый путь — то, что агент правит. Требования:

- писаемый под UID контейнера;
- **тот же абсолютный путь, что и на хосте**, если планируешь возить
  `sessions/` между контейнером и хостовой инсталляцией: в логе сессии
  workspace записан абсолютным путём, и при несовпадении resume откроет
  сессию с битым cwd.

### Чего монтировать НЕ надо

`node_modules` самого dsh, `/usr/local/lib/node_modules` — они принадлежат
слою образа и должны пересобираться при апгрейде, а не переживать его.

---

## 2. Главная засада: `--host 0.0.0.0` запрещён

Это первое, обо что спотыкается любой докеризатор. CLI **намеренно** отвергает
привязку ко всем интерфейсам:

```
error: --host 0.0.0.0 is intentionally not supported yet for safety:
it would expose remote code execution to the network; use 127.0.0.1 instead
```

Источник — `packages/bundle/web-app/src/startup.ts:74-76`. Проверка стоит
в парсере флагов, а не в сервере.

Сам сервер при этом `0.0.0.0` **умеет**: схема конфига
`packages/host/webserver/src/index.ts:126` принимает
`z.union([z.const('127.0.0.1'), z.const('0.0.0.0')])`. Запрещён только флаг.

В bridge-сети Docker это ломает обычный `-p`: `docker-proxy` ходит на IP
контейнера, а процесс слушает петлю внутри netns — соединения не будет.

Три рабочих выхода, по возрастанию риска.

### Вариант A — `--network host` (рекомендую для локалки)

Ничего не патчим. Контейнер живёт в netns хоста, dsh слушает хостовый
`127.0.0.1:3080`, браузер открывает его напрямую. Loopback-only остаётся
loopback-only — гарантия безопасности не ослаблена.

Минусы: только Linux, порт не изолирован от хоста.

### Вариант B — bridge + cordis-патч

Меняем строку сервера в композиции. Патч кладётся в
`$DSH_HOME/cordis.patch.yml` (машинный слой, применяется последним —
`docs/user/develop/basic/publish.md:118`).

**Патч заменяет `config` целевой строки целиком**, поэтому надо перечислить
все ключи, а не только `host`:

```yaml
# $DSH_HOME/cordis.patch.yml
- id: webserver
  config:
    host: '0.0.0.0'
    port: 3080
    compression: gzip
    compressionLevel: 1
    compressionThresholdBytes: 1024

# /api-фаервол пускает только петлю и явно перечисленные authority.
# Без этой строки браузер получит отказ на каждый вызов API.
- id: connection
  config:
    trustedHosts: !!js "['localhost:3080', 'dsh.example.com', ...ctx.webRuntime.trustedHosts]"
```

Публикуем **только на петлю хоста**: `-p 127.0.0.1:3080:3080`. Наружу —
через reverse-proxy с собственной аутентификацией.

Побочный эффект: захардкодив `port`, ты теряешь флаг `--port` (в исходной
строке там `!!js ctx.webStartup.port ?? 3080`).

То же самое без патча даёт CLI-флаг `--trusted-host <authority...>`
(повторяемый) — но он не меняет `host`, только фаервол.

### Вариант C — socat/Caddy внутри контейнера

Так делает большинство community-образов: dsh слушает петлю, рядом в
контейнере прокси форвардит `eth0:3080 → 127.0.0.1:3081`. По риску
эквивалентно варианту B, кода больше. Смысл появляется только если прокси
заодно даёт Basic Auth.

### Про безопасность — прямо

`/api`-фаервол проверяет **только HTTP-заголовки** (`Host`/`Origin`).
Это защита от DNS-rebinding, а не аутентификация. Аутентификация — токен
запуска: `dsh web` печатает URL с `?token=...`, первый `GET /` обменивает
его на подписанную куку (`packages/client/connection/src/browser-auth.ts`,
время жизни куки 30 дней по умолчанию).

Отсюда: **любой, кто дотянулся до порта, получает удалённое исполнение кода
на твоей машине.** `SAFETY.md:20` прямым текстом советует одноразовую ВМ или
контейнер. Не публикуй 3080 в LAN и тем более в интернет без прокси
с авторизацией.

---

## 3. Dockerfile

```dockerfile
# syntax=docker/dockerfile:1.7

# ─ базовый образ ────────────────────────────────────────────────────────────
# node:24-trixie (не -slim): buildpack-deps уже несёт компилятор, а он нужен
# node-gyp'у, когда плагин тянет нативный модуль (например node-pty).
# package.json харнесса требует node ^22.19.0 || >=24.
FROM node:24-trixie AS base

ARG DSH_VERSION=0.1.2-rc.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      tini \
      git openssh-client ca-certificates \
      ripgrep jq curl \
      bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# pnpm нужен команде `dsh plugin` (она проксирует в pnpm внутри профиля).
# Для одного лишь `dsh web` на дефолтном профиле он не требуется.
RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"

# ─ пользователь и пути ──────────────────────────────────────────────────────
# Образ node уже содержит пользователя node с uid/gid 1000.
ENV DSH_HOME=/home/node/.dsh \
    HOME=/home/node

RUN mkdir -p /home/node/.dsh /workspace \
 && chown -R node:node /home/node /workspace

USER node
WORKDIR /workspace

EXPOSE 3080

# tini обязателен: агент порождает shell- и PTY-процессы, без init-а
# они становятся сиротами, а сигналы не доходят до dsh.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["dsh", "web", "--no-open", "--port", "3080"]
```

`--no-open` обязателен: в контейнере нет браузера, и попытка его открыть даёт
шум в логе.

`bubblewrap` в списке пакетов — не украшение. Локальный sandbox-бэкенд
(`packages/sandbox/sandbox-local`) пробует `bwrap`, `landlock-run`, Seatbelt
или Windows ACL, определяет работоспособность функционально и **закрывается
при неудаче** (fail-closed). Без `bwrap` внутри контейнера песочница для
инструментов может просто не подняться.

---

## 4. Запуск

### Вариант A — host-сеть, минимум движений

```bash
docker build -t dsh:0.1.2-rc.1 .

docker run -d --name dsh \
  --network host \
  --init \
  -v dsh-home:/home/node/.dsh \
  -v /path/to/projects:/path/to/projects \
  -w /path/to/projects \
  dsh:0.1.2-rc.1

# URL с токеном:
docker logs dsh 2>&1 | grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*'
```

Проект смонтирован по совпадающему пути — сессии переносимы между
контейнером и хостовым dsh.

### Вариант B — compose с bridge и патчем

```yaml
# compose.yaml
services:
  dsh:
    build: .
    init: true
    restart: unless-stopped

    # публикация только на петлю хоста
    ports:
      - "127.0.0.1:3080:3080"

    volumes:
      - dsh-home:/home/node/.dsh
      - ./cordis.patch.yml:/home/node/.dsh/cordis.patch.yml:ro
      - ${PROJECTS_DIR:-./projects}:/workspace

    environment:
      DSH_HOME: /home/node/.dsh
      # Ключи — только через окружение/секреты, никогда в образ и не в ARG.
      DEEPSEEK_API_KEY: ${DEEPSEEK_API_KEY:?set it in .env}

    # Ограничение привилегий. read_only:true не ставим — dsh пишет
    # в DSH_HOME и в workspace; ограничиваемся снятием capabilities.
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    tmpfs:
      - /tmp:size=512m

    healthcheck:
      # без токена корень отдаёт 401 — это и есть признак живого сервера
      test: ["CMD-SHELL", "curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/ | grep -qE '401|200'"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 40s

volumes:
  dsh-home:
```

`cordis.patch.yml` — файл из варианта B выше, лежит рядом с compose.

---

## 5. Куда положить ключи

Не в `Dockerfile`, не в `ARG`, не в слой образа. Варианты:

1. Через UI: Settings → Models, ключ уходит в `$DSH_HOME/.credentials.yaml`
   (write-only, страница обратно получает только маскированный дескриптор).
2. Через окружение + ссылка `apiKeyEnv` в `settings.yaml`.
3. Docker secrets / внешний менеджер, смонтированный файлом.

Важная деталь про дочерние процессы: **подсистема subprocess вычищает
из окружения всё, что похоже на кредо** — имена по `/KEY|PASSWORD|SECRET|TOKEN/i`
плюс все `DSH_*`. Плагин, которому нужна конкретная переменная в спавне,
обязан объявить её в своём `env`-слое явно. Так что «просто экспортнуть»
переменную и ждать, что MCP-сервер её увидит, — не сработает.

---

## 6. Апгрейд

`DSH_HOME` переживает смену образа, слой системы — нет. Порядок:

```bash
docker compose build --build-arg DSH_VERSION=<новая>
docker compose up -d
```

Что проверить после:

- **`ERR_PNPM_UNEXPECTED_STORE`** при работе с плагинами — том `dsh-home`
  создан другой мажорной версией pnpm. Store профиля надо пересоздать:
  `docker compose exec dsh sh -c 'cd $DSH_HOME/profiles/web && rm -rf node_modules && pnpm install'`.
- **ABI-разъезд плагинов.** Плагины ставятся из npm/git и линкуются против
  внутренних пакетов харнесса. Смена rc может переименовать экспорт —
  и плагин упадёт на загрузке. `dsh --profile web --dump-config` показывает
  собранную композицию по слоям и помогает локализовать виновника.
- **Пресеты.** Между версиями id пресетов переименовываются. Сессия, чей лог
  ссылается на исчезнувший id, при resume даёт
  `agent-presets: preset "X" not found`.

---

## 7. Диагностика

| Симптом | Причина |
|---|---|
| `-p 3080:3080` даёт connection refused | dsh слушает петлю внутри netns; вариант A или B |
| API 403/отказ, UI грузится | Host не в `trustedHosts`; добавь `--trusted-host` или патч `connection` |
| `EACCES` в `/workspace` | UID bind-mount'а не 1000; `chown -R 1000:1000` на хосте или `--user` |
| `EROFS` в файловом браузере | Браузер стартует с `os.homedir()`; сделай `HOME` писаемым |
| Зомби-процессы после turn'ов | Нет init; `--init` или tini в ENTRYPOINT |
| Инструменты падают на песочнице | Нет `bwrap` в образе, бэкенд закрылся fail-closed |
| Плагины не грузятся | `pnpm` не в образе или `dsh.profile.bundles` не синхронизирован |

Полезное:

```bash
docker compose exec dsh dsh --profile web --dump-config   # собранная композиция
docker compose exec dsh sh -c 'ls -la $DSH_HOME'
docker compose logs -f dsh
```

---

## 8. Готовые образы

Если собирать не хочется — на 2026-08 есть несколько community-проектов
(upstream своего образа не даёт). Ни один не является официальным;
перед использованием стоит прочитать их Dockerfile, потому что образ
получает полный доступ к смонтированному коду и ключам.

| Проект | Подход |
|---|---|
| `runzhliu/deepseek-harness-docker` | multi-stage, hardened compose, Helm StatefulSet; тот же cordis-патч для `0.0.0.0` |
| `smanx/deepseek-harness` (Docker Hub) | встроенный Node reverse-proxy поверх loopback |
| `niyueee/dsh-container` | universal dev-container base + Caddy, Podman Quadlet |
| `Xidong-AI/deepseek-harness-web-docker` | dsh + Caddy Basic Auth, GHCR |

---

## 9. Что на самом деле надо перенести на новый хост

Это самая недооценённая часть. Инстинкт «забэкаплю `~/.dsh` и всё» —
**неверный**. Ниже инвентаризация, снятая с живой инсталляции на этой машине.

### 9.1. Состояние живёт в четырёх разных местах

| Где | Что | Размер здесь |
|---|---|---|
| `~/.dsh/` | сессии, профили, настройки, ключи, workspaces, пресеты, attachments | ~2.6 ГБ |
| `~/.ouroboros/` | **вне `DSH_HOME`**: `ouroboros.db`, `seeds/`, `data/`, `worktrees/`, `config.yaml`, `credentials.yaml` | ~4 МБ |
| `~/.hindsight/` | **вне `DSH_HOME`**: `installation/`, `instances/` — банк долговременной памяти | зависит от режима |
| вне `$HOME` | целевые каталоги `link:`-зависимостей профиля | зависит |

Пропустишь второй или третий пункт — перенесётся харнесс, но **не опыт**:
Seed'ы, поколения эволюции и накопленные знания по репозиториям останутся
на старом хосте.

### 9.2. Три ловушки, из-за которых «скопировал ~/.dsh» не работает

**(а) Профиль ссылается наружу.** В `profiles/<name>/package.json` живой
инсталляции две зависимости — не из реестра:

```json
"@linxin666/dsh-web-all": "link:/mnt/82A2.../dsh-plugins-collection/dsh-web/packages/dsh-web-all",
"dsh_plugin_ad":          "link:/mnt/82A2.../dsh-plugins-collection/dsh_plugin_ad"
```

`link:` — это симлинк на каталог за пределами `DSH_HOME`. Перенёс только
`~/.dsh` → симлинки повисли → профиль не собирается. Такие зависимости надо
либо переносить вместе с целевыми каталогами по тем же путям, либо перед
переездом заменить на версии из реестра.

Найти их у себя:

```bash
grep -nE '"(link|file|portal):' ~/.dsh/profiles/*/package.json
```

**(б) Пути записаны абсолютными.** `storages/workspace.json` хранит
workspaces как абсолютные пути:

```json
{"path": "/mnt/82A23910A2390A65/Trade/.../test/WS_01"}
```

А каталоги сессий именованы кодировкой пути:

```
~/.dsh/sessions/--mnt-82A23910A2390A65-Trade-...-deepseek-harness--/
~/.dsh/sessions/--home-uadmin-.dsh-bench-workspace--/
```

Отсюда **главное правило переезда: сохраняй абсолютные пути**. Проект,
лежавший в `/mnt/X/proj`, должен оказаться в `/mnt/X/proj` и на новом хосте.
Иначе workspaces в UI укажут в пустоту, а resume откроет сессию с битым cwd.
Это же правило диктует и то, как монтировать в контейнер (см. §1).

**(в) Память hindsight зависит от выбранного режима.** Три варианта, и
переносимость у них разная:

| Режим | Где память | Переезд |
|---|---|---|
| `cloud` | Hindsight Cloud | ничего не переносить — нужен только токен |
| `self-hosted` | твой сервер | ничего не переносить — нужен URL |
| `daemon` | локальный `hindsight-embed` на `127.0.0.1:9077` | **переносить `~/.hindsight` целиком** |

В режиме `daemon` база выбирается полем `daemonProfile`
(`HINDSIGHT_DAEMON_PROFILE`, по умолчанию `coding-agent`) — это и есть тот
самый накопленный опыт. Если переносимость между хостами важна, `cloud` или
`self-hosted` снимают вопрос полностью: память перестаёт быть состоянием
машины.

### 9.3. Переносимый бэкап

```bash
#!/usr/bin/env bash
# dsh-export.sh — снимок всего состояния
set -euo pipefail
OUT="${1:?usage: dsh-export.sh /path/to/out.tar.zst}"

tar --zstd -cf "$OUT" \
  -C "$HOME" \
    .dsh \
    .ouroboros \
    .hindsight \
  --exclude='.dsh/profiles/*/node_modules' \
  --exclude='.dsh/logs' \
  --exclude='.ouroboros/logs' \
  --exclude='.ouroboros/worktrees'

echo "OK: $(du -h "$OUT" | cut -f1)"
```

`node_modules` профилей исключены сознательно: это 2.5 ГБ восстановимого
кэша, и он привязан к версии Node и к платформе. На новом хосте:

```bash
tar --zstd -xf snapshot.tar.zst -C "$HOME"
dsh plugin --profile <ваш-профиль> install     # пересобрать node_modules
```

Что бэкап **не** содержит и о чём надо позаботиться отдельно: целевые
каталоги `link:`-зависимостей, сами рабочие репозитории и всё, что лежит по
абсолютным путям вне `$HOME`.

---

## 10. Firecracker

### 10.1. Что это и когда оправдано

Firecracker — минималистичный VMM на Rust поверх KVM. Загружает гостевое
Linux-ядро примерно за **125 мс** при накладных расходах **менее 5 МиБ** на
микро-ВМ. Один процесс на одну ВМ, никакого хост-демона. Эмулирует горстку
virtio-устройств вместо сорока с лишним у QEMU. Под ним крутятся AWS Lambda
и Fargate.

Для dsh мотив ровно один и он серьёзный: **своё ядро**. Docker-контейнер —
это забор, а не стена: агент делит ядро с хостом. `SAFETY.md` харнесса прямо
говорит, что песочница инструментов имеет пределы, и рекомендует одноразовую
ВМ. Firecracker даёт границу, которую нельзя перешагнуть эскалацией в ядре,
по цене, близкой к контейнерной.

Второй мотив — **снапшоты**. Это единственный способ сохранить *работающий*
харнесс целиком, вместе с оперативной памятью, и поднять его позже другим
процессом.

### 10.2. Чего Firecracker не умеет — и почему это решающее

**У Firecracker нет ни virtio-fs, ни 9P.** Не «выключено по умолчанию», а
отсутствует: устройства virtio-9p нет, а публикуемые гостевые ядра собраны
без 9P-клиента. Никакой опцией это не включается. У Cloud Hypervisor
virtio-fs есть, у Firecracker — нет.

Отсюда прямое следствие: **`-v /host/path:/container/path` аналога не
существует.** Тот способ, которым в §4 монтировался рабочий каталог, в
Firecracker недоступен в принципе. Остаются три пути:

| Способ | Как | Цена |
|---|---|---|
| Внутри rootfs | код и `~/.dsh` живут в образе диска | всё в одном файле — отлично для переноса, но хост не видит файлы |
| Отдельный блок-девайс | второй `drive` с ext4 под данные | хост может смонтировать его, **но не одновременно с гостем** |
| NFSv4.1 | гостевые ядра Firecracker несут NFS-клиент (v4.1, не v3) | живой доступ с обеих сторон, но нужен NFS-сервер на хосте |

Для «редактирую в IDE на хосте, агент правит в ВМ» рабочий вариант ровно
один — NFSv4.1. Гостевому образу Firecracker для этого даже не нужен
`mount.nfs`: `mount -t nfs4` с явными `addr=` и `clientaddr=` уходит прямо
в ядро.

Проверить своё ядро: `CONFIG_NFS_V4_1`, `CONFIG_NET_9P`.

### 10.3. Снапшоты переносимы не так, как кажется

Снапшот выглядит как три файла, которые можно скопировать куда угодно.
Это не так, и ошибка молчаливая.

- **CPU.** Снапшот, снятый на хосте с AVX-512 и восстановленный там, где
  AVX-512 нет, **восстановится успешно**. Пройдёт health-check. Отработает
  несколько запросов. А потом гость дойдёт до кода, скомпилированного под
  AVX-512, получит `#UD` и умрёт. Гость не перезапускает feature detection —
  он продолжает с уже принятыми решениями. Асимметрия: снять на слабом CPU и
  восстановить на сильном — нормально; наоборот — мина. Intel↔AMD не
  поддерживается вовсе.
- **Лечится CPU-шаблоном** (`T2`, `T2S`, `T2CL`, `T2A`, `C3`): гостю
  навязывается фиксированный CPUID и набор MSR. Шаблон надо применять
  **при снятии**, а не при восстановлении — задним числом убрать фичу,
  на которую гость уже заложился, невозможно. Шаблон выбирается по самому
  слабому хосту парка.
- **Версии Firecracker.** Новая версия обычно восстановит снапшот старой;
  старая новую — нет.
- **Ядро хоста.** Снятие и восстановление на разных версиях хостового ядра
  официально считается нестабильным.
- **Файл памяти нужен постоянно.** При восстановлении Firecracker делает
  `MAP_PRIVATE` на файл памяти и подгружает страницы по требованию. Файл
  обязан существовать всё время жизни восстановленной ВМ — это не
  «загрузили и забыли».

Практический вывод: снапшот — отличный инструмент для **быстрого старта на
однородном парке** и посредственный для «перенесу на любую машину через
полгода». Для второго сценария надёжнее обычный rootfs-образ плюс экспорт
состояния из §9.3.

### 10.4. Практическая схема

Минимальный набор: ядро (`vmlinux`), rootfs (ext4-образ), TAP-интерфейс,
JSON-конфиг. rootfs удобнее всего собрать из уже готового Docker-образа —
тогда §3 не пропадает зря:

```bash
# 1. Собрать образ по Dockerfile из §3
docker build -t dsh:fc .

# 2. Экспортировать файловую систему в ext4
docker create --name dsh-tmp dsh:fc
docker export dsh-tmp | tar -x -C ./rootfs
docker rm dsh-tmp

truncate -s 8G rootfs.ext4
mkfs.ext4 -d ./rootfs rootfs.ext4

# 3. Ядро — готовое из бакета quickstart Firecracker,
#    либо своё с CONFIG_NFS_V4_1=y
```

`vm.json`:

```json
{
  "boot-source": {
    "kernel_image_path": "vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=172.16.0.2::172.16.0.1:255.255.255.0::eth0:off"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "rootfs.ext4",
      "is_root_device": true,  "is_read_only": false },
    { "drive_id": "state",  "path_on_host": "dsh-home.ext4",
      "is_root_device": false, "is_read_only": false }
  ],
  "network-interfaces": [
    { "iface_id": "eth0", "host_dev_name": "tap0" }
  ],
  "machine-config": { "vcpu_count": 4, "mem_size_mib": 8192,
                      "cpu_template": "T2CL" }
}
```

Запуск — обязательно через `jailer`, не голым бинарём: он уводит сам VMM в
chroot, отдельные namespace, cgroup и seccomp-фильтр. Гипервизор здесь тоже
считается потенциально скомпрометированным.

```bash
jailer --id dsh-01 --exec-file $(which firecracker) \
       --uid 1000 --gid 1000 --chroot-base-dir /srv/jail \
       -- --config-file vm.json
```

**`dsh-home.ext4` вторым диском — ключевое решение.** Состояние из §9
отделено от системы: обновление харнесса = замена `rootfs.ext4`, диск
состояния не трогается. Он же — единица переноса на другой хост: один файл,
внутри которого уже лежит всё, что перечислено в §9.1, вместе с абсолютными
путями, которые не поедут.

Сеть: dsh слушает `127.0.0.1:3080` внутри гостя. Наружу — либо
`--host 0.0.0.0` через cordis-патч из §2 плюс `trustedHosts` (в микро-ВМ это
уже честная граница, а не дырка в заборе), либо SSH-туннель на TAP-адрес.

### 10.5. Стоит ли брать Cloud Hypervisor вместо Firecracker

Для этой задачи — возможно, да. Он тоже KVM-based и тоже лёгкий, но:

- **virtio-fs есть** — то есть живое монтирование рабочего каталога с хоста
  работает как в Docker, без NFS-обвязки;
- есть живая миграция (`send-migration` / `receive-migration`), в том числе
  postcopy;
- есть hotplug CPU и памяти.

Firecracker выигрывает, когда нужны сотни микро-ВМ и минимальная поверхность
атаки. Для одной длинноживущей dev-ВМ с примонтированным репозиторием
ограничения Firecracker (нет virtio-fs) бьют ровно по больному месту, а его
преимущества (плотность, 125 мс) не нужны.

---

## 11. Сравнение: Docker против Firecracker

### По существу

| Критерий | Docker | Firecracker |
|---|---|---|
| Граница | namespaces + cgroups + seccomp, **ядро общее** | своё ядро, KVM, + jailer вокруг VMM |
| Старт | ~1 с | ~125 мс |
| Накладные расходы | почти нет | < 5 МиБ на ВМ |
| Требования к хосту | Docker | **KVM** — bare metal или вложенная виртуализация |
| Живой монтаж каталога хоста | `-v`, тривиально | **невозможно**; только NFSv4.1 или блок-девайс |
| Единица переноса | образ + именованные тома (перечисляешь сам) | один файл rootfs / диск состояния |
| Снапшот с памятью | нет | есть, но привязан к CPU, ядру хоста и версии VMM |
| Экосистема | огромная | control plane пишешь сам |
| Сеть | из коробки | TAP-интерфейсы руками |
| Не-Linux хосты | да (через ВМ) | нет |

### Через призму переносимости — что здесь важнее всего

**Docker.** Состояние = набор томов, и **перечислять их приходится
вручную**. Как показал §9, интуитивный список («`~/.dsh` и репозиторий»)
неполон: `~/.ouroboros` и `~/.hindsight` лежат вне `DSH_HOME`, а профиль
ссылается `link:`-ами наружу. Забыл том — потерял опыт, и заметишь ты это
не сразу. Зато перенос честно кросс-платформенный и кросс-архитектурный.

**Firecracker.** Состояние = файл диска. Переносится **и то, о чём ты
забыл**, потому что переносится файловая система целиком. Это главный
аргумент в пользу микро-ВМ именно для накопленного опыта: единица переноса
совпадает с границей состояния, а не требует его инвентаризации. Цена —
неоднородность парка перестаёт быть бесплатной: снапшоты требуют CPU-шаблонов,
а без снапшотов теряется главный бонус.

**Общее для обоих и не решаемое ни тем, ни другим:** абсолютные пути внутри
`workspace.json` и в именах каталогов сессий. Оба подхода обязаны сохранять
пути. Firecracker здесь чуть удобнее — внутри ВМ путь целиком твой и не
зависит от того, как устроен новый хост.

### Что выбрать

| Ситуация | Ответ |
|---|---|
| Одна машина, свои репозитории, нужна опрятность | **Docker**, `--network host` |
| Агент трогает чужой или недоверенный код | **Firecracker** (или Cloud Hypervisor) |
| Часто переезжаешь между хостами, опыт терять нельзя | **Firecracker**, диск состояния отдельным файлом |
| Нужен живой монтаж репозитория с хоста | **Docker** или **Cloud Hypervisor**, не Firecracker |
| macOS/Windows хост | **Docker** |
| Десятки параллельных изолированных агентов | **Firecracker** |
| Нет KVM (обычная облачная ВМ без вложенной виртуализации) | **Docker**, выбора нет |

Разумный гибрид, если тянет в обе стороны: держать Dockerfile как источник
истины для окружения, а rootfs для Firecracker собирать из него через
`docker export` (§10.4). Тогда одна сборка обслуживает оба режима, и
переключение между ними не требует переписывать окружение заново.

---

## Источники

- `packages/bundle/web-app/src/startup.ts:74` — запрет `--host 0.0.0.0`
- `packages/host/webserver/src/index.ts:126` — схема `host`/`port`
- `packages/client/connection/src/index.ts:70` — `trustedHosts`, `/api` fence
- `packages/client/connection/src/browser-auth.ts` — обмен токена на куку
- `packages/bundle/web-app/cordis.patch.yml:116` — исходная строка `webserver`
- `docs/user/develop/basic/publish.md:114-118` — порядок слоёв патчей
- `docs/config-catalog.md:2076` — `DSH_HOME`
- `SAFETY.md:11-20` — границы песочницы

Инвентаризация состояния (§9) снята с живой инсталляции:

- `~/.dsh/profiles/<профиль>/package.json` — `link:`-зависимости наружу
- `~/.dsh/storages/workspace.json` — абсолютные пути workspaces
- `~/.dsh/sessions/` — имена каталогов кодируют абсолютный путь
- `.../node_modules/@vectorize-io/hindsight-coding-agents/README.md`,
  раздел «Where memory lives» — три режима памяти и `daemonProfile`

Firecracker (§10–11):

- <https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/versioning.md>
  — совместимость снапшотов по CPU, ядру хоста и версии VMM
- <https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md>
  — `MAP_PRIVATE` и требование держать файл памяти
- <https://pandastack.ai/blog/firecracker-cpu-templates-explained> — шаблоны
  T2/T2S/T2CL/T2A/C3, применение при снятии
- <https://pandastack.ai/blog/firecracker-vcpu-templates-cross-cpu-snapshots>
  — молчаливый отказ через SIGILL при переезде на более слабый CPU
- <https://mountx.vercel.app/guide/vms> — отсутствие 9P-клиента в гостевых
  ядрах Firecracker, NFSv4.1 как единственный путь
- <https://miget.com/blog/cloud-hypervisor-vs-firecracker> — сравнение,
  virtio-fs и живая миграция у Cloud Hypervisor
