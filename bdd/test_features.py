from pathlib import Path

from pytest_bdd import given, scenarios, then


ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ROOT / "host-local/docker/compose.yaml"
DOCKERFILE = ROOT / "host-local/docker/Dockerfile"
RUNNER = ROOT / "host-local/docker/run-dsh.sh"
MAKEFILE = ROOT / "host-local/Makefile"
TASK_RUNNER = ROOT / "host-local/docker/run-task.sh"
SMOKE = ROOT / "host-local/docker/smoke.sh"

scenarios("features/dsh-docker-runtime.feature")


@given("Docker compose для локального DSH", target_fixture="compose_text")
def compose_text() -> str:
    return COMPOSE.read_text()


@given("host-local Makefile для Docker", target_fixture="make_text")
def make_text() -> str:
    return MAKEFILE.read_text()


@then("сервис использует host network")
def host_network(compose_text: str) -> None:
    assert "network_mode: host" in compose_text


@then("BrowserSkill daemon управляется отдельным Compose сервисом")
def supervised_bsk(compose_text: str) -> None:
    assert "  bsk:" in compose_text
    assert "container_name: bsk-daemon" in compose_text
    assert "restart: unless-stopped" in compose_text
    assert "/host-local/docker/run-bsk.sh" in compose_text


@then("команда DSH содержит флаг no-open")
def no_open() -> None:
    assert "--no-open" in RUNNER.read_text()


@then("DSH запускается пользователем 1000:1000")
def uid_gid(compose_text: str) -> None:
    assert 'user: "${DSH_UID:-1000}:${DSH_GID:-1000}"' in compose_text


@then("DSH_HOME смонтирован из домашнего каталога пользователя")
def dsh_home(compose_text: str) -> None:
    assert "source: /home/uadmin/.dsh" in compose_text
    assert "target: /home/uadmin/.dsh" in compose_text


@then("BrowserSkill IPC смонтирован из домашнего каталога пользователя")
def bsk_home(compose_text: str) -> None:
    assert "source: /home/uadmin/.bsk" in compose_text
    assert "target: /home/uadmin/.bsk" in compose_text


@then("рабочий диск смонтирован по тому же абсолютному пути")
def mount_root(compose_text: str) -> None:
    path = "/mnt/82A23910A2390A65"
    assert compose_text.count(path) >= 2


@then("pnpm store профиля находится в записываемом DSH_HOME")
def writable_pnpm_store(compose_text: str) -> None:
    expected = "PNPM_CONFIG_STORE_DIR: /home/uadmin/.dsh/.pnpm-store"
    assert expected in compose_text
    assert "PNPM_CONFIG_STORE_DIR=/home/uadmin/.dsh/.pnpm-store" in DOCKERFILE.read_text()
    for script in (RUNNER, ROOT / "host-local/docker/prepare.sh"):
        assert 'PNPM_CONFIG_STORE_DIR="${PNPM_CONFIG_STORE_DIR:-$DSH_HOME/.pnpm-store}"' in script.read_text()


@then("credentials не копируются в Docker image")
def no_credentials_copy() -> None:
    dockerfile = DOCKERFILE.read_text().lower()
    assert "copy " not in dockerfile
    assert ".credentials" not in dockerfile


@then("build prepare bdd redundancy start и smoke имеют отдельные цели")
def stages(make_text: str) -> None:
    for target in (
        "docker-build:",
        "docker-prepare:",
        "bdd:",
        "docker-redundancy:",
        "docker-up:",
        "docker-smoke:",
    ):
        assert target in make_text


@then("стадии записывают receipt с duration и exit code")
def receipts() -> None:
    runner = TASK_RUNNER.read_text()
    assert "durationSeconds" in runner
    assert "exitCode" in runner


@then("smoke проверяет Codex Claude и BrowserSkill CLI")
def cli_smoke() -> None:
    smoke = SMOKE.read_text()
    for command in ("command -v codex", "command -v claude", "command -v bsk"):
        assert command in smoke
    assert "bsk status --json" in smoke
