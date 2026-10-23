#!/usr/bin/env bash
# pick-model.sh — pick the biggest model that fits and pull it into the Ollama container.
#
# Usage: ./pick-model.sh [-f family] [-s size] [-l] [-n] [-h]
#   -f family   model family (default: qwen2.5-coder)
#   -s size     force a size tag, e.g. 7b (still falls back smaller on failure)
#   -l          use Ollama installed on the host instead of the container
#   -n          dry run: print the choice, pull nothing
#   -h          help
# Env:
#   RAM_GB=16     override detected memory
#   COMPOSE=...   compose command (default: "podman compose" if podman exists, else "docker compose")
#   USE_GPU=1     container has NVIDIA GPU passthrough: size by free VRAM
set -euo pipefail

FAMILY="qwen2.5-coder"
FORCE_SIZE=""
DRY_RUN=0
LOCAL=0

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warn: $*" >&2; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

while getopts "f:s:lnh" opt; do
  case "$opt" in
    f) FAMILY="$OPTARG" ;;
    s) FORCE_SIZE="$OPTARG" ;;
    l) LOCAL=1 ;;
    n) DRY_RUN=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] && FAMILY="$1"

# Size ladder, largest first. Min budget (GB) to run it, approx download GB (Q4).
SIZES=(32b 14b 7b 3b 1.5b 0.5b)
NEED_GB=(28 14 8 4 2 0)
DISK_GB=(20 9 5 2 1 1)

OS="$(uname -s)"; ARCH="$(uname -m)"

# ---- how to reach ollama ----------------------------------------------------
if [ -z "${COMPOSE:-}" ]; then
  if   command -v podman >/dev/null 2>&1; then COMPOSE="podman compose"
  elif command -v docker >/dev/null 2>&1; then COMPOSE="docker compose"
  else COMPOSE=""; fi
fi

run_ollama() {
  if [ "$LOCAL" -eq 1 ]; then ollama "$@"
  else $COMPOSE exec -T ollama ollama "$@"; fi
}
in_container() { $COMPOSE exec -T ollama "$@"; }

if [ "$LOCAL" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  [ -n "$COMPOSE" ] || die "no podman or docker found. Install podman, or use -l for host Ollama"
fi
if [ "$LOCAL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  command -v ollama >/dev/null 2>&1 || die "ollama not found on host. Install: https://ollama.com/download"
fi

# Bring the ollama container up if needed (container mode, real run only)
ollama_ready() { run_ollama list >/dev/null 2>&1; }
if [ "$LOCAL" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if ! ollama_ready; then
    warn "ollama container not ready, running: $COMPOSE up -d ollama"
    $COMPOSE up -d ollama || die "could not start ollama container (is 'podman machine start' done?)"
    for _ in $(seq 1 30); do ollama_ready && break; sleep 1; done
    ollama_ready || die "ollama container did not become ready"
  fi
fi
if [ "$LOCAL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  if ! ollama_ready; then
    warn "host Ollama not running, starting 'ollama serve' in background"
    log="${TMPDIR:-/tmp}/ollama-serve.log"
    nohup ollama serve >"$log" 2>&1 &
    for _ in $(seq 1 20); do ollama_ready && break; sleep 1; done
    ollama_ready || die "Ollama failed to start; see $log"
  fi
fi

# ---- memory detection -------------------------------------------------------
# Container mode: the container sees the Linux VM's memory (podman machine / Docker VM),
# NOT the Mac's. That is the number that matters.
host_ram_gb() {
  local kb bytes
  if [ "$OS" = "Darwin" ]; then
    bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
    is_int "$bytes" || return 1
    echo $(( bytes / 1024 / 1024 / 1024 ))
  elif [ -r /proc/meminfo ]; then
    kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    is_int "$kb" || return 1
    echo $(( kb / 1024 / 1024 ))
  else return 1; fi
}

container_ram_gb() {
  local kb
  kb=$(in_container sh -c "grep MemTotal /proc/meminfo" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)
  is_int "$kb" || return 1
  echo $(( kb / 1024 / 1024 ))
}

where="host"
if [ -n "${RAM_GB:-}" ]; then
  is_int "$RAM_GB" || die "RAM_GB must be an integer, got '$RAM_GB'"
  total=$RAM_GB; where="RAM_GB override"
elif [ "$LOCAL" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && total=$(container_ram_gb); then
  where="container VM"
elif total=$(host_ram_gb); then
  where="host"
  [ "$LOCAL" -eq 0 ] && warn "using host RAM; real limit is your podman machine memory (podman machine inspect)"
else
  die "cannot detect RAM; set RAM_GB=<n>"
fi

vram_gb=0
if [ "$LOCAL" -eq 1 ] || [ "${USE_GPU:-0}" = "1" ]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    mb=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null \
          | sort -nr | head -1 | tr -d ' ' || true)
    is_int "$mb" && vram_gb=$(( mb / 1024 ))
  fi
fi

if [ "$vram_gb" -gt 0 ]; then
  budget=$vram_gb;                src="NVIDIA free VRAM"
elif [ "$LOCAL" -eq 1 ] && [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then
  budget=$(( total * 65 / 100 )); src="Apple unified memory (65% of ${total}GB, ${where})"
else
  budget=$(( total * 6 / 10 ));   src="RAM, CPU only (60% of ${total}GB, ${where})"
fi

# ---- pick starting rung -----------------------------------------------------
start=-1
if [ -n "$FORCE_SIZE" ]; then
  for i in "${!SIZES[@]}"; do [ "${SIZES[$i]}" = "$FORCE_SIZE" ] && start=$i; done
  [ "$start" -ge 0 ] || die "unknown size '$FORCE_SIZE' (choose: ${SIZES[*]})"
  src="forced via -s"
else
  for i in "${!SIZES[@]}"; do
    if [ "$budget" -ge "${NEED_GB[$i]}" ]; then start=$i; break; fi
  done
  [ "$start" -ge 0 ] || start=$(( ${#SIZES[@]} - 1 ))
fi

echo "memory budget: ${budget}GB (${src})"
echo "family: ${FAMILY}, starting at: ${SIZES[$start]}"
if [ "$LOCAL" -eq 0 ] && [ "$OS" = "Darwin" ]; then
  echo "note: containers on macOS run CPU only. Expect slow tokens/sec; prefer a smaller size for demos."
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: would pull ${FAMILY}:${SIZES[$start]} (falls back smaller on failure)"
  exit 0
fi

# ---- disk space -------------------------------------------------------------
free_gb=0
if [ "$LOCAL" -eq 1 ]; then
  disk_dir="${OLLAMA_MODELS:-$HOME/.ollama}"; [ -d "$disk_dir" ] || disk_dir="$HOME"
  free_kb=$(df -Pk "$disk_dir" 2>/dev/null | awk 'NR==2 {print $4}')
else
  free_kb=$(in_container df -Pk /root/.ollama 2>/dev/null | awk 'NR==2 {print $4}' | tr -d '\r' || true)
fi
is_int "${free_kb:-}" && free_gb=$(( free_kb / 1024 / 1024 ))
echo "free disk for models: ${free_gb}GB"

# ---- pull with fallback -----------------------------------------------------
chosen=""
for (( i=start; i<${#SIZES[@]}; i++ )); do
  size="${SIZES[$i]}"; model="${FAMILY}:${size}"

  if run_ollama list 2>/dev/null | awk 'NR>1 {print $1}' | tr -d '\r' | grep -qx "$model"; then
    echo "already installed: $model"; chosen="$model"; break
  fi

  need=$(( ${DISK_GB[$i]} + 2 ))
  if [ "$free_gb" -gt 0 ] && [ "$free_gb" -lt "$need" ]; then
    warn "skip $model: needs ~${need}GB free, have ${free_gb}GB"
    continue
  fi

  echo "pulling: $model"
  if run_ollama pull "$model"; then
    chosen="$model"; break
  fi
  warn "pull failed for $model (no such tag, network, or disk). Trying a smaller size."
done

[ -n "$chosen" ] || die "no model could be pulled for family '$FAMILY'"

# ---- verify and record ------------------------------------------------------
run_ollama list | tr -d '\r' | awk 'NR>1 {print $1}' | grep -qx "$chosen" \
  || warn "$chosen not listed after pull; check '$COMPOSE exec ollama ollama list'"

tmp=$(mktemp "${TMPDIR:-/tmp}/model.XXXXXX")
echo "$chosen" > "$tmp" && mv "$tmp" .model
echo "done. model: $chosen (saved to .model)"
