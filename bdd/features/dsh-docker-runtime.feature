Feature: Локальный DSH в Docker

  @REQ-dsh-docker-runtime-001
  Scenario: Контейнер запускает web без нового окна браузера
    Given Docker compose для локального DSH
    Then сервис использует host network
    And BrowserSkill daemon управляется отдельным Compose сервисом
    And команда DSH содержит флаг no-open
    And DSH запускается пользователем 1000:1000

  @REQ-dsh-docker-runtime-002
  Scenario: Существующее состояние и абсолютные пути сохраняются
    Given Docker compose для локального DSH
    Then DSH_HOME смонтирован из домашнего каталога пользователя
    And BrowserSkill IPC смонтирован из домашнего каталога пользователя
    And рабочий диск смонтирован по тому же абсолютному пути
    And pnpm store профиля находится в записываемом DSH_HOME
    And credentials не копируются в Docker image

  @REQ-dsh-docker-runtime-003
  Scenario: Развёртывание имеет независимые проверяемые стадии
    Given host-local Makefile для Docker
    Then build prepare bdd redundancy start и smoke имеют отдельные цели
    And стадии записывают receipt с duration и exit code
    And smoke проверяет Codex Claude и BrowserSkill CLI
