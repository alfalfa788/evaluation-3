#!/usr/bin/env bash
set -euo pipefail

HARBOR_VERSION=0.21.0
HARBOR_COMMIT=64afbbcb62165950301e1a6407c729aa26d844ff
HARBOR_REPOSITORY=https://github.com/harbor-framework/harbor.git
PYTHON_VERSION=3.12
TESTED_NODE_VERSION=22.19.0
TESTED_BUN_VERSION=1.3.14
MINIMUM_MACOS_DOCKER_DESKTOP_VERSION=4.86.0
KERNEL_PROBE_IMAGE=alpine:3.23.4
PROXY_HOST=app-llmproxy.dataannotation.tech
EGRESS_TEST_HOST=${HARBOR_INSTALLER_EGRESS_TEST_HOST:-$PROXY_HOST}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OPENCODE_PATCHER=${SCRIPT_DIR}/apply_opencode_fix.sh
ANTIGRAVITY_PATCH=${SCRIPT_DIR}/antigravity_sdk_base_url.patch
WSL_EGRESS_PATCH=${SCRIPT_DIR}/wsl_egress_kernel_probe.patch

warnings=()
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/harbor-installer.XXXXXX")
checkout=${work_dir}/harbor
step_log=${work_dir}/step.log
smoke_image=
smoke_container=
smoke_network=

cleanup() {
  set +e
  if [[ -n "$smoke_container" ]]; then
    docker rm --force "$smoke_container" >/dev/null 2>&1
  fi
  if [[ -n "$smoke_network" ]]; then
    docker network rm "$smoke_network" >/dev/null 2>&1
  fi
  if [[ -n "$smoke_image" ]]; then
    docker image rm --force "$smoke_image" >/dev/null 2>&1
  fi
  rm -rf "$work_dir"
}

finish() {
  status=$?
  cleanup
  if ((${#warnings[@]})); then
    printf '\nWarnings:\n' >&2
    for warning in "${warnings[@]}"; do
      printf '  - %s\n' "$warning" >&2
    done
  fi
  return "$status"
}
trap finish EXIT

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

run_step() {
  label=$1
  guidance=$2
  shift 2
  printf '%s... ' "$label"
  : > "$step_log"
  if "$@" >"$step_log" 2>&1; then
    printf 'done\n'
    return
  fi
  printf 'failed\n' >&2
  cat "$step_log" >&2
  if [[ -n "$guidance" ]]; then
    printf '\nNext step: %s\n' "$guidance" >&2
  fi
  exit 1
}

run_quiet() {
  label=$1
  shift
  run_step "$label" "" "$@"
}

run_guided() {
  label=$1
  guidance=$2
  shift 2
  run_step "$label" "$guidance" "$@"
}

[[ "$EGRESS_TEST_HOST" =~ ^[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?$ ]] || \
  fail "Invalid Harbor egress test host: $EGRESS_TEST_HOST"

is_wsl2() {
  [[ -r /proc/sys/kernel/osrelease ]] &&
    grep -qiE 'microsoft-standard-WSL2|WSL2' /proc/sys/kernel/osrelease
}

docker_nftables_guidance() {
  if [[ "$(uname -s)" == Darwin ]]; then
    printf 'Docker Desktop %s or newer is required; restart Docker Desktop, verify the active Docker context, and retry' \
      "$MINIMUM_MACOS_DOCKER_DESKTOP_VERSION"
  elif is_wsl2; then
    printf "Run 'wsl --update' and 'wsl --shutdown' from Windows PowerShell, then retry"
  else
    printf 'Use a Docker daemon kernel with CONFIG_NFT_FIB_INET enabled, then retry'
  fi
}

check_docker_nftables_support() {
  docker run --rm "$KERNEL_PROBE_IMAGE" sh -c \
    "if [ ! -f /proc/config.gz ]; then exit 0; fi; \
zcat /proc/config.gz 2>/dev/null | grep -qE '^CONFIG_NFT_FIB_INET=[ym]'"
}

configure_wsl_docker_credentials() {
  is_wsl2 || return 0

  local packages=(pass gnupg2 golang-docker-credential-helpers)
  local missing_packages=()
  local package
  for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
      missing_packages+=("$package")
    fi
  done

  if ((${#missing_packages[@]})); then
    command -v apt-get >/dev/null 2>&1 || \
      fail "WSL2 Docker credentials require apt-get packages: ${packages[*]}"
    command -v sudo >/dev/null 2>&1 || \
      fail "sudo was not found. Install these WSL2 packages as root: ${packages[*]}"
    printf 'Installing WSL2 Docker credential packages (sudo may prompt)...\n'
    sudo apt-get install -y "${packages[@]}" || \
      fail "Could not install WSL2 Docker credential packages. Run: sudo apt-get install -y ${packages[*]}"
  fi

  for command in pass gpg docker-credential-pass; do
    command -v "$command" >/dev/null 2>&1 || \
      fail "$command was not found after installing the WSL2 Docker credential packages"
  done

  local pass_key=
  if [[ -s "$HOME/.password-store/.gpg-id" ]]; then
    pass_key=$(head -n 1 "$HOME/.password-store/.gpg-id")
    if ! gpg --batch --list-secret-keys "$pass_key" >/dev/null 2>&1; then
      pass_key=
    fi
  fi

  if [[ -z "$pass_key" ]]; then
    local identity='Joseph Pietrzak <frostbomber@gmail.com>'
    pass_key=$(
      gpg --batch --with-colons --list-secret-keys "$identity" 2>/dev/null |
        awk -F: '$1 == "sec" { print $5; exit }' || true
    )
    if [[ -z "$pass_key" ]]; then
      run_guided "Generating the WSL2 Docker credential key" \
        "Run: gpg --batch --passphrase '' --quick-generate-key '$identity' default default" \
        gpg --batch --passphrase '' --quick-generate-key "$identity" default default
      pass_key=$(
        gpg --batch --with-colons --list-secret-keys "$identity" 2>/dev/null |
          awk -F: '$1 == "sec" { print $5; exit }' || true
      )
    fi
    [[ -n "$pass_key" ]] || fail "Could not find the generated WSL2 Docker credential key"
    run_guided "Initializing pass for Docker" \
      "Run 'gpg --list-secret-keys --keyid-format LONG', then run 'pass init <ID after sec rsa.../>'" \
      pass init "$pass_key"
  fi

  local docker_dir=${DOCKER_CONFIG:-$HOME/.docker}
  local docker_config=${docker_dir}/config.json
  local expected_config
  expected_config=$(printf '{\n    "credsStore": "pass"\n}\n')
  mkdir -p "$docker_dir"
  if [[ ! -f "$docker_config" ]] || [[ "$(cat "$docker_config")" != "$expected_config" ]]; then
    if [[ -e "$docker_config" ]]; then
      local backup=${docker_config}.harbor-installer-backup.$(date +%Y%m%d%H%M%S)
      cp -p "$docker_config" "$backup"
      warnings+=("Existing Docker config was backed up to $backup")
    fi
    printf '%s\n' "$expected_config" > "$docker_config"
    chmod 600 "$docker_config"
  fi

  run_guided "Validating the WSL2 Docker credential store" \
    "Confirm $docker_config contains only { \"credsStore\": \"pass\" }, then run 'docker-credential-pass list'" \
    docker-credential-pass list
}

for command in git uv docker; do
  if command -v "$command" >/dev/null 2>&1; then
    continue
  fi
  case "$command" in
    git)
      fail "Git was not found. Inside WSL, run: sudo apt-get update && sudo apt-get install -y git"
      ;;
    uv)
      fail "Linux uv was not found. Inside WSL, run: curl -LsSf https://astral.sh/uv/install.sh | sh"
      ;;
    docker)
      fail "Docker was not found. Install Docker Desktop in Windows and enable Settings > Resources > WSL Integration"
      ;;
  esac
done

docker info >/dev/null 2>&1 || \
  fail "Docker is not running. Start Docker Desktop, enable WSL integration, and restart this WSL shell"
docker buildx version >/dev/null 2>&1 || \
  fail "Docker Buildx is required. Enable Docker Desktop's WSL integration and retry"
docker compose version >/dev/null 2>&1 || \
  fail "Docker Compose is required. Enable Docker Desktop's WSL integration and retry"

docker_nftables_next_step=$(docker_nftables_guidance)
run_guided "Checking Docker nftables support" "$docker_nftables_next_step" \
  check_docker_nftables_support

uv_path=$(command -v uv)
uv_tool_dir=$(uv tool dir)
case "$uv_path:$uv_tool_dir" in
  *.exe:*|/mnt/[a-zA-Z]/*:*|*:[a-zA-Z]:\\*|*:*\\*)
    fail "Windows uv.exe detected. Install the Linux uv binary inside WSL and retry"
    ;;
esac

configure_wsl_docker_credentials

for path in "$OPENCODE_PATCHER" "$ANTIGRAVITY_PATCH" "$WSL_EGRESS_PATCH"; do
  [[ -f "$path" ]] || \
    fail "Patch resource missing: $path. Download and extract a fresh ummon-worker-tools.zip"
done

run_guided "Installing managed Python ${PYTHON_VERSION}" \
  "Check WSL internet access, then reinstall the Linux uv binary if the download still fails" \
  uv python install "$PYTHON_VERSION"
validation_python=$(uv python find --managed-python --no-project "$PYTHON_VERSION")

run_guided "Cloning Harbor v${HARBOR_VERSION}" \
  "Confirm WSL can reach github.com over HTTPS, then retry" \
  git clone --quiet --depth 1 --branch "v${HARBOR_VERSION}" \
  "$HARBOR_REPOSITORY" "$checkout"

actual_version=$(
  "$validation_python" - "$checkout/pyproject.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as file:
    print(tomllib.load(file)["project"]["version"])
PY
)
[[ "$actual_version" == "$HARBOR_VERSION" ]] || \
  fail "cloned Harbor checkout is version $actual_version, expected ${HARBOR_VERSION}"

actual_commit=$(git -C "$checkout" rev-parse HEAD)
[[ "$actual_commit" == "$HARBOR_COMMIT" ]] || \
  fail "Harbor v${HARBOR_VERSION} resolved to unexpected commit $actual_commit"

apply_patches() {
  cd "$checkout"
  bash "$OPENCODE_PATCHER"
  git apply --check --directory=src "$ANTIGRAVITY_PATCH"
  git apply --directory=src "$ANTIGRAVITY_PATCH"
  git apply --check --directory=src "$WSL_EGRESS_PATCH"
  git apply --directory=src "$WSL_EGRESS_PATCH"
}
run_guided "Applying worker patches" \
  "Download a fresh worker-tools archive; its patches must match Harbor v${HARBOR_VERSION}" \
  apply_patches

run_guided "Validating patched Python" \
  "Download a fresh worker-tools archive and retry; the patched source did not compile" \
  "$validation_python" -m py_compile \
  "$checkout/src/harbor/agents/installed/opencode.py" \
  "$checkout/src/harbor/agents/installed/antigravity_sdk.py" \
  "$checkout/src/harbor/agents/installed/antigravity_sdk_runner.py" \
  "$checkout/src/harbor/environments/docker/docker.py"
run_guided "Validating the Antigravity runner lock" \
  "Upgrade the Linux uv binary inside WSL, download a fresh worker-tools archive, and retry" \
  uv lock --check --script \
  "$checkout/src/harbor/agents/installed/antigravity_sdk_runner.py"

smoke_image="swequal-harbor-egress-smoke:$$"
smoke_container="swequal-harbor-egress-smoke-$$"
smoke_network="swequal-harbor-egress-smoke-$$"
sidecar_context="$checkout/src/harbor/environments/docker/harbor-docker-egress-control-sidecar"
run_guided "Building the restricted-network probe" \
  "Run 'docker buildx version'; if it fails, repair Docker Desktop's WSL integration" \
  env DOCKER_BUILDKIT=1 docker build --quiet --tag "$smoke_image" "$sidecar_context"

start_egress_probe() {
  docker network create "$smoke_network" >/dev/null
  docker run --detach --name "$smoke_container" --network "$smoke_network" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --env EGRESS_CONTROL_INITIAL_NETWORK_MODE=public \
    --entrypoint /opt/egress-sidecar/entrypoint.sh \
    "$smoke_image"
  for _ in {1..30}; do
    if docker exec "$smoke_container" test -f \
      /tmp/harbor-docker-egress-control-sidecar.ready; then
      return
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$smoke_container")" != true ]]; then
      docker logs "$smoke_container"
      return 1
    fi
    sleep 1
  done
  docker logs "$smoke_container"
  return 1
}
run_guided "Starting the restricted-network probe" \
  "$docker_nftables_next_step" \
  start_egress_probe

apply_allowlist() {
  if ! docker exec "$smoke_container" network-policy allow "$EGRESS_TEST_HOST"; then
    docker logs "$smoke_container"
    printf '\nThe Docker daemon kernel cannot enforce Harbor restricted networking.\n' >&2
    printf 'Next step: %s\n' "$docker_nftables_next_step" >&2
    printf 'The iptables-legacy workaround does not apply because Harbor uses nftables directly.\n' >&2
    return 1
  fi
}
run_quiet "Applying the Docker restricted-network policy" apply_allowlist

probe_http() {
  target=$1
  docker run --rm --network "container:${smoke_container}" alpine:3.23.4 \
    wget --server-response --output-document=/dev/null --timeout=15 "$target" 2>&1 || true
}

validate_restricted_network() {
  allowed_output=$(probe_http "https://${EGRESS_TEST_HOST}/")
  grep -Eq 'HTTP/[0-9.]+ [1-5][0-9][0-9]' <<<"$allowed_output" || {
    printf '%s\n\n' "$allowed_output"
    if grep -qiE 'bad address|name or service not known|temporary failure in name resolution' <<<"$allowed_output"; then
      printf 'Could not resolve %s from Harbor restricted networking.\n' "$EGRESS_TEST_HOST"
      printf 'Check WSL DNS and Docker Desktop WSL integration, then run wsl --shutdown from PowerShell.\n'
    else
      printf 'Could not reach https://%s through the Harbor allowlist.\n' "$EGRESS_TEST_HOST"
      printf 'Check the worker proxy, VPN, firewall, and WSL internet access, then retry.\n'
    fi
    return 1
  }

  denied_output=$(probe_http "https://example.com/")
  if grep -Eq 'HTTP/[0-9.]+ [1-5][0-9][0-9]' <<<"$denied_output"; then
    printf 'non-allowlisted host remained reachable\n'
    return 1
  fi

  docker exec "$smoke_container" network-policy deny-all >/dev/null
  blocked_output=$(probe_http "https://${EGRESS_TEST_HOST}/")
  if grep -Eq 'HTTP/[0-9.]+ [1-5][0-9][0-9]' <<<"$blocked_output"; then
    printf 'allowlisted host remained reachable after the no-network transition\n'
    return 1
  fi
}
run_quiet "Testing allowlist and no-network transitions" validate_restricted_network

docker rm --force "$smoke_container" >/dev/null
smoke_container=
docker network rm "$smoke_network" >/dev/null
smoke_network=
docker image rm --force "$smoke_image" >/dev/null
smoke_image=

viewer_built=false
if command -v bun >/dev/null 2>&1; then
  command -v node >/dev/null 2>&1 || \
    fail "Node.js is required to build the Harbor viewer. Install Node.js ${TESTED_NODE_VERSION}, or remove Bun from PATH to install API-only Harbor"
  run_guided "Building the Harbor viewer" \
    "Install Node.js ${TESTED_NODE_VERSION} and Linux Bun ${TESTED_BUN_VERSION} inside WSL, or remove Bun from PATH to install API-only Harbor" \
    bash "$checkout/scripts/build-viewer.sh"
  [[ -f "$checkout/src/harbor/viewer/static/index.html" ]] || \
    fail "Harbor viewer build did not produce index.html. Install Node.js ${TESTED_NODE_VERSION} and Linux Bun ${TESTED_BUN_VERSION}, or remove Bun from PATH for an API-only install"
  viewer_built=true
else
  warnings+=("Bun was not found; Harbor was installed without the viewer UI")
fi

run_guided "Installing patched Harbor v${HARBOR_VERSION}" \
  "Check disk space and permissions under 'uv tool dir', confirm Linux uv is selected, and retry" \
  uv tool install --force --python "$validation_python" "$checkout"

tool_dir=$(uv tool dir)
tool_bin_dir=$(uv tool dir --bin)
installed_python=${tool_dir}/harbor/bin/python
installed_harbor=${tool_bin_dir}/harbor

case ":$PATH:" in
  *":${tool_bin_dir}:"*) ;;
  *)
    export PATH="${tool_bin_dir}:$PATH"
    warnings+=("${tool_bin_dir} is not permanently on PATH; add it to the WSL shell configuration")
    ;;
esac
hash -r
active_harbor=$(command -v harbor || true)

for path in "$installed_python" "$installed_harbor"; do
  [[ -x "$path" ]] || \
    fail "Harbor executable missing at $path. Remove the Harbor uv tool, confirm Linux uv is selected, and rerun this installer"
done

validate_active_harbor() {
"$validation_python" - "$installed_harbor" "$active_harbor" <<'PY'
import os
import sys

installed = os.path.realpath(sys.argv[1])
active = os.path.realpath(sys.argv[2]) if sys.argv[2] else None
if active != installed:
    raise SystemExit(
        f"error: patched Harbor was installed at {installed}, but PATH resolves "
        f"harbor to {active or '<not found>'}"
    )
PY
}
run_guided "Checking the active Harbor command" \
  "Add $(uv tool dir --bin) to PATH, run 'hash -r', and retry" \
  validate_active_harbor

validate_installed_harbor() {
"$installed_python" - "$viewer_built" <<'PY'
import inspect
import sys
from pathlib import Path

import harbor
from harbor.agents.factory import AgentFactory
from harbor.agents.installed.opencode import OpenCode
from harbor.environments.docker.docker import DockerEnvironment
from harbor.models.agent.name import AgentName

if "antigravity-sdk" not in AgentName.values():
    raise SystemExit("error: installed Harbor does not accept antigravity-sdk")
if AgentName.ANTIGRAVITY_SDK not in AgentFactory._AGENT_MAP:
    raise SystemExit("error: installed Harbor does not register antigravity-sdk")
if 'stall_flag = "/logs/agent/.opencode_stalled"' not in inspect.getsource(OpenCode):
    raise SystemExit("error: installed Harbor is missing the OpenCode patch")
if "sys.platform == \"linux\"" in inspect.getsource(DockerEnvironment.__init__):
    raise SystemExit("error: installed Harbor is missing the WSL egress probe patch")
if sys.argv[1] == "true":
    viewer_index = Path(harbor.__file__).parent / "viewer" / "static" / "index.html"
    if not viewer_index.is_file():
        raise SystemExit(
            f"error: viewer was built but is missing from installed Harbor: {viewer_index}"
        )
PY
}
run_guided "Validating the installed Harbor patches" \
  "Remove the Harbor uv tool and rerun this installer from a fresh worker-tools archive" \
  validate_installed_harbor

validate_harbor_version() {
  [[ "$("$installed_harbor" --version)" == "$HARBOR_VERSION" ]]
}
run_guided "Checking the Harbor version" \
  "Remove the Harbor uv tool and rerun this installer" \
  validate_harbor_version

printf 'Patched Harbor v%s installed at %s\n' "$HARBOR_VERSION" "$installed_harbor"
