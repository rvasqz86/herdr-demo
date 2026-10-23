#!/usr/bin/env bash
# install.sh — build and start the herdr + Copilot CLI sandbox, then verify the isolation.
#
# Usage: ./install.sh [--rebuild] [--verify] [--down] [-h]
#   (no flags)  create workspace/, build images, start containers, run verification
#   --rebuild   build with --no-cache first
#   --verify    only run the verification checks against running containers
#   --down      stop and remove containers (keeps the login volume)
#   -h          help
# Env:
#   COMPOSE=...   compose command, e.g. "docker compose" (default: auto-detect podman, then docker)
set -euo pipefail

REBUILD=0; VERIFY_ONLY=0; DOWN=0

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --verify)  VERIFY_ONLY=1 ;;
    --down)    DOWN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

cd "$(dirname "$0")"

# ---- pick a container runtime ----------------------------------------------
if [ -z "${COMPOSE:-}" ]; then
  if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
    if podman compose version >/dev/null 2>&1; then COMPOSE="podman compose"
    elif command -v podman-compose >/dev/null 2>&1; then COMPOSE="podman-compose"
    else die "podman found but no compose provider. Install one: brew install podman-compose"; fi
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
    docker compose version >/dev/null 2>&1 || die "docker found but 'docker compose' is missing"
    COMPOSE="docker compose"
  else
    die "neither podman nor docker found. Install podman: brew install podman podman-compose"
  fi
else
  RUNTIME="${COMPOSE%% *}"
fi
info "using: $COMPOSE"

# ---- runtime reachable? -----------------------------------------------------
if ! "$RUNTIME" info >/dev/null 2>&1; then
  if [ "$RUNTIME" = "podman" ] && [ "$(uname -s)" = "Darwin" ]; then
    die "podman is not reachable. Start the VM: podman machine start"
  fi
  die "$RUNTIME is not reachable. Is the daemon/service running?"
fi

if [ "$DOWN" -eq 1 ]; then
  info "stopping containers"
  $COMPOSE down
  exit 0
fi

# ---- verification -----------------------------------------------------------
PASS=0; FAIL=0
check() {  # check "description" expect(pass|fail) command...
  local desc="$1" expect="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if { [ "$expect" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$expect" = fail ] && [ "$rc" -ne 0 ]; }; then
    echo "  PASS  $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc (exit $rc, expected $expect)"; FAIL=$((FAIL+1))
  fi
}

verify() {
  info "verifying sandbox"
  local sb="$COMPOSE exec -T sandbox"
  check "runs as non-root"                          pass  $sb sh -c '[ "$(id -u)" != 0 ]'
  check "herdr installed"                           pass  $sb sh -c "command -v herdr"
  check "copilot installed"                         pass  $sb sh -c "command -v copilot"
  check "root filesystem mounted read-only"         pass  $sb sh -c "grep -qE '^[^ ]+ / [^ ]+ ro[, ]' /proc/mounts"
  check "GitHub API reachable through proxy"        pass  $sb curl -sS -m 10 -o /dev/null https://api.github.com
  check "example.com blocked by proxy"              fail  $sb curl -sS -m 10 -o /dev/null https://example.com
  check "direct internet blocked (no proxy)"        fail  $sb curl -sS -m 5 --noproxy '*' -o /dev/null https://api.github.com
  check "no ~/.ssh in sandbox"                      fail  $sb sh -c "test -e \$HOME/.ssh"
  echo "  $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
  verify || die "verification failed; see FAIL lines. Proxy log: $COMPOSE logs egress-proxy"
  exit 0
fi

# ---- build and start --------------------------------------------------------
info "creating workspace/"
mkdir -p workspace

if [ "$REBUILD" -eq 1 ]; then
  info "building images (no cache)"
  $COMPOSE build --no-cache
fi

info "building and starting containers"
$COMPOSE up -d --build

info "waiting for containers"
for _ in $(seq 1 30); do
  if $COMPOSE exec -T sandbox true >/dev/null 2>&1 && $COMPOSE ps 2>/dev/null | grep -qi squid; then break; fi
  sleep 1
done

if verify; then
  echo
  info "ready. Start herdr:"
  echo "    $COMPOSE exec -it sandbox herdr"
  echo "  then in a pane: copilot   (first time: /login)"
else
  echo
  warn_msg="some checks failed. Proxy log: $COMPOSE logs egress-proxy"
  echo "warn: $warn_msg" >&2
  echo "The sandbox is running, but do not demo until the FAIL lines are fixed." >&2
  exit 1
fi
