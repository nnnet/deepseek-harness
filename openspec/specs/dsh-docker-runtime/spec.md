# dsh-docker-runtime Specification

## Purpose
Воспроизводимый локальный запуск обновлённого DeepSeek Harness в Docker без
хостового процесса DSH и без открытия новых окон браузера.

## Requirements

### Requirement: REQ-dsh-docker-runtime-001 Изолированный запуск
DSH SHALL запускаться непривилегированным пользователем в Docker с флагом
`--no-open`, сохраняя веб-интерфейс доступным только через loopback хоста.
BrowserSkill daemon SHALL работать как отдельный Compose-сервис с политикой
`restart: unless-stopped`, чтобы порт 52800 не зависел от процесса ChatGPT.

#### Scenario: Контейнер не открывает браузер
- **WHEN** оператор запускает Docker deployment
- **THEN** DSH работает с host network на `127.0.0.1:3080`
- **AND** команда запуска содержит `--no-open`

### Requirement: REQ-dsh-docker-runtime-002 Сохранение существующего состояния
Контейнер SHALL использовать существующие `~/.dsh` и `~/.bsk`, а также
монтировать рабочий диск по тому же абсолютному пути, не копируя credentials
или сессии в образ. Все операции pnpm с профилем SHALL использовать единый
записываемый store внутри `~/.dsh`, чтобы установка и удаление плагинов не
зависели от read-only mount `~/.local` и сохранялись после рестарта.

#### Scenario: Профиль и workspace доступны по прежним путям
- **WHEN** контейнер запускается с профилем `web`
- **THEN** `DSH_HOME` указывает на bind mount `/home/uadmin/.dsh`
- **AND** `/mnt/82A23910A2390A65` смонтирован без изменения пути
- **AND** pnpm store находится внутри `/home/uadmin/.dsh`

### Requirement: REQ-dsh-docker-runtime-003 Проверяемое развёртывание
Каждая стадия deployment SHALL иметь отдельную make-цель, лог и terminal
receipt, а итоговая smoke-проверка MUST подтверждать health, UID/GID и наличие
Codex, Claude и BrowserSkill CLI внутри контейнера.

#### Scenario: Deployment завершается проверкой готовности
- **WHEN** выполняется агрегированная цель `docker-deploy`
- **THEN** build, prepare, BDD, redundancy gate, start и smoke идут fail-fast
- **AND** каждая стадия сохраняет длительность и exit code
