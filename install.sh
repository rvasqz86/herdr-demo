#!/usr/bin/env bash
# install.sh — build and start the herdr + Copilot CLI sandbox, then verify the isolation.
#
# Usage: ./install.sh [--pull] [--ca NAME | --ca-file PATH] [--list-ca] [--rebuild] [--verify] [--down] [-h]
#   (no flags)       create workspace/, build images, start containers, run verification
#   --ca NAME        export company root CA(s) whose name matches NAME from the macOS System
#                    keychain into certs/corp-ca.crt, then rebuild (e.g. --ca Zscaler)
#   --ca-file PATH   copy a root CA file (PEM) into certs/corp-ca.crt, then rebuild
#   --list-ca        list certificate names in the macOS System keychain, then exit
#   --pull           use the prebuilt image from ghcr.io instead of building (no build-time downloads)
#   --rebuild        build with --no-cache first
#   --verify        only run the verification checks against running containers
#   --down           stop and remove containers (keeps the login volume)
#   -h               help
# Env:
#   COMPOSE=...      compose command, e.g. "docker compose" (default: auto-detect podman, then docker)
#
# Use --ca on networks that re-sign HTTPS (curl error 60). It keeps TLS verification ON; never use curl -k.
set -euo pipefail

REBUILD=0; VERIFY_ONLY=0; DOWN=0; LIST_CA=0; PULL=0; CA_NAME=""; CA_FILE=""

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warn: $*" >&2; }
info() { echo "==> $*"; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ca)       [ $# -ge 2 ] || die "--ca needs a name, e.g. --ca Zscaler"; CA_NAME="$2"; shift ;;
    --ca-file)  [ $# -ge 2 ] || die "--ca-file needs a path"; CA_FILE="$2"; shift ;;
    --list-ca)  LIST_CA=1 ;;
    --pull)     PULL=1 ;;
    --rebuild)  REBUILD=1 ;;
    --verify)   VERIFY_ONLY=1 ;;
    --down)     DOWN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")"

# ---- company CA handling (no container runtime needed) ----------------------
KEYCHAIN=/Library/Keychains/System.keychain
CA_OUT=certs/corp-ca.crt

count_certs() { grep -c 'BEGIN CERTIFICATE' "$1" 2>/dev/null || true; }

if [ "$LIST_CA" -eq 1 ]; then
  [ "$(uname -s)" = "Darwin" ] || die "--list-ca needs macOS (uses the System keychain)"
  info "certificates in the System keychain (look for your company or proxy vendor):"
  security find-certificate -a "$KEYCHAIN" | sed -n 's/.*"labl"<blob>="\(.*\)"/  \1/p' | sort -u
  echo "Then: ./install.sh --ca \"<name>\""
  exit 0
fi

if [ -n "$CA_NAME" ] && [ -n "$CA_FILE" ]; then die "use either --ca or --ca-file, not both"; fi

if [ -n "$CA_NAME" ] || [ -n "$CA_FILE" ]; then
  mkdir -p certs
  tmp="$(mktemp "${TMPDIR:-/tmp}/ca.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  if [ -n "$CA_NAME" ]; then
    [ "$(uname -s)" = "Darwin" ] || die "--ca needs macOS (System keychain). Use --ca-file PATH instead"
    info "exporting certificates matching '$CA_NAME' from the System keychain"
    security find-certificate -a -c "$CA_NAME" -p "$KEYCHAIN" > "$tmp" 2>/dev/null || true
    [ "$(count_certs "$tmp")" -gt 0 ] || die "no certificate named '$CA_NAME' found. Run: ./install.sh --list-ca"
  else
    [ -r "$CA_FILE" ] || die "cannot read $CA_FILE"
    cp "$CA_FILE" "$tmp"
    [ "$(count_certs "$tmp")" -gt 0 ] || die "$CA_FILE is not a PEM certificate (no BEGIN CERTIFICATE). Convert DER with: openssl x509 -inform der -in file.cer -out file.pem"
  fi
  n="$(count_certs "$tmp")"
  [ "$n" -le 5 ] || warn "$n certificates matched; the name may be too broad. Check $CA_OUT"
  install -m 0644 "$tmp" "$CA_OUT"
  info "wrote $n certificate(s) to $CA_OUT (git-ignored)"
  # A local build bakes the CA into the image trust store, so rebuild. A pulled image reads it at
  # runtime from the mounted certs/ directory instead.
  [ "$PULL" -eq 1 ] || REBUILD=1
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "note: if podman image pulls fail with a certificate error, the Podman VM needs the CA too (see README)."
  fi
fi

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
  check "herdr config installed (~/.config/herdr)"  pass  $sb sh -c 'test -d "$HOME/.config/herdr/.git"'
  check "interactive shell is bash (SHELL, login shell)" pass  $sb sh -c '[ "$SHELL" = /bin/bash ] && getent passwd agent | grep -q ":/bin/bash$"'
  check "hq launcher on PATH"                       pass  $sb sh -c 'command -v hq'
  check "dev tools installed (nvim rg jq lazygit fd bat fzf)" pass  $sb sh -c 'for t in nvim rg jq lazygit fd bat fzf; do command -v $t >/dev/null || exit 1; done'
  check "root filesystem mounted read-only"         pass  $sb sh -c "grep -qE '^[^ ]+ / [^ ]+ ro[, ]' /proc/mounts"
  # Trust bundle = system CAs + optional company CA from the mounted certs/ directory
  check "GitHub API reachable through proxy"        pass  $sb sh -c 'cat /etc/ssl/certs/ca-certificates.crt /certs/corp-ca.crt > /tmp/bundle.crt 2>/dev/null; curl -sS -m 10 --cacert /tmp/bundle.crt -o /dev/null https://api.github.com'
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

if [ "$PULL" -eq 1 ]; then
  info "pulling prebuilt sandbox image"
  $COMPOSE pull sandbox || die "could not pull the image. Is the package public, or are you logged in? See README (Prebuilt image)"
  info "starting containers"
  $COMPOSE up -d
else
  if [ "$REBUILD" -eq 1 ]; then
    info "building images (no cache)"
    $COMPOSE build --no-cache
  fi
  info "building and starting containers"
  $COMPOSE up -d --build
fi

info "waiting for containers"
for _ in $(seq 1 30); do
  if $COMPOSE exec -T sandbox true >/dev/null 2>&1 && $COMPOSE ps 2>/dev/null | grep -qi squid; then break; fi
  sleep 1
done

if verify; then
  echo
  info "ready. Start herdr:"
  echo "    $COMPOSE exec -it sandbox herdr"
  echo "  then in a pane, first time only:  copilot login --device-code"
  echo "  (open the printed URL on your Mac, enter the code), then run: copilot"
else
  echo
  echo "warn: some checks failed. Proxy log: $COMPOSE logs egress-proxy" >&2
  echo "The sandbox is running, but do not demo until the FAIL lines are fixed." >&2
  exit 1
fi
