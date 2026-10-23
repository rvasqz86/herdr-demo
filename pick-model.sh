#!/usr/bin/env bash
# pick-model.sh — pick the biggest model that fits this Mac, pull it with native Ollama, and
# verify it actually runs on the GPU (Metal). If it spills to CPU, drop to a smaller size.
#
# Usage: ./pick-model.sh [-f family] [-s size] [-k] [-n] [-h]
#   -f family   model family (default: qwen2.5-coder)
#   -s size     force a starting size tag, e.g. 7b (still falls back smaller on failure)
#   -k          skip the warm-up and GPU check
#   -n          dry run: print the choice, pull nothing
#   -h          help
# Env:
#   RAM_GB=16        override detected memory
#   REQUIRE_GPU=1    enforce the GPU check even when no GPU is detected
set -euo pipefail

FAMILY="qwen2.5-coder"
FORCE_SIZE=""
DRY_RUN=0
SKIP_CHECK=0
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warn: $*" >&2; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

while getopts "f:s:knh" opt; do
  case "$opt" in
    f) FAMILY="$OPTARG" ;;
    s) FORCE_SIZE="$OPTARG" ;;
    k) SKIP_CHECK=1 ;;
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

# ---- memory detection -------------------------------------------------------
if [ -n "${RAM_GB:-}" ]; then
  is_int "$RAM_GB" || die "RAM_GB must be an integer, got '$RAM_GB'"
  total=$RAM_GB
elif [ "$OS" = "Darwin" ]; then
  bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
  is_int "$bytes" || die "cannot read hw.memsize; set RAM_GB=<n>"
  total=$(( bytes / 1024 / 1024 / 1024 ))
elif [ -r /proc/meminfo ]; then
  kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  is_int "$kb" || die "cannot parse /proc/meminfo; set RAM_GB=<n>"
  total=$(( kb / 1024 / 1024 ))
else
  die "cannot detect RAM on $OS; set RAM_GB=<n>"
fi

vram_gb=0
if command -v nvidia-smi >/dev/null 2>&1; then
  mb=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null \
        | sort -nr | head -1 | tr -d ' ' || true)
  is_int "$mb" && vram_gb=$(( mb / 1024 ))
fi

gpu_expected=0
if [ "$vram_gb" -gt 0 ]; then
  budget=$vram_gb;                src="NVIDIA free VRAM";                          gpu_expected=1
elif [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then
  # Apple silicon unified memory: Metal can use roughly 65-75% of total
  budget=$(( total * 65 / 100 )); src="Apple unified memory (65% of ${total}GB)";  gpu_expected=1
else
  [ "$OS" = "Darwin" ] && warn "Intel Mac: Ollama has no Metal acceleration here, expect CPU speed"
  budget=$(( total * 6 / 10 ));   src="RAM, CPU only (60% of ${total}GB)"
fi
[ "${REQUIRE_GPU:-0}" = "1" ] && gpu_expected=1

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

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: would pull ${FAMILY}:${SIZES[$start]} (falls back smaller on failure or CPU spill)"
  exit 0
fi

# ---- ollama availability ----------------------------------------------------
command -v ollama >/dev/null 2>&1 || die "ollama not found. Install: brew install ollama (or https://ollama.com/download)"
command -v curl   >/dev/null 2>&1 || die "curl not found"

server_up() { curl -fsS -m 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; }

if ! server_up; then
  warn "Ollama not reachable at $OLLAMA_URL, starting 'ollama serve' in background"
  log="${TMPDIR:-/tmp}/ollama-serve.log"
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-2m}" \
  OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}" \
  OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}" \
    nohup ollama serve >"$log" 2>&1 &
  for _ in $(seq 1 20); do server_up && break; sleep 1; done
  server_up || die "Ollama failed to start; see $log"
fi

# ---- disk space -------------------------------------------------------------
disk_dir="${OLLAMA_MODELS:-$HOME/.ollama}"
[ -d "$disk_dir" ] || disk_dir="$HOME"
free_kb=$(df -Pk "$disk_dir" 2>/dev/null | awk 'NR==2 {print $4}')
free_gb=0
is_int "${free_kb:-}" && free_gb=$(( free_kb / 1024 / 1024 ))
echo "free disk: ${free_gb}GB in ${disk_dir}"

# ---- GPU check --------------------------------------------------------------
# Load the model with a 1-token request, then read the PROCESSOR column of `ollama ps`.
# Returns 0 if fully on GPU, 1 if it spills to CPU or the check cannot run.
gpu_ok() {
  local model="$1" line
  curl -fsS -m 300 "$OLLAMA_URL/api/generate" \
    -d "{\"model\":\"$model\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1}}" \
    >/dev/null 2>&1 || { warn "warm-up request failed for $model"; return 1; }
  line=$(ollama ps 2>/dev/null | awk -v m="$model" '$1 == m')
  [ -n "$line" ] || { warn "$model not shown by 'ollama ps' after warm-up"; return 1; }
  echo "  ollama ps: $(echo "$line" | tr -s ' ')"
  echo "$line" | grep -q "100% GPU"
}

# ---- pull, verify, fall back ------------------------------------------------
chosen=""
for (( i=start; i<${#SIZES[@]}; i++ )); do
  size="${SIZES[$i]}"; model="${FAMILY}:${size}"

  if ! ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$model"; then
    need=$(( ${DISK_GB[$i]} + 2 ))
    if [ "$free_gb" -gt 0 ] && [ "$free_gb" -lt "$need" ]; then
      warn "skip $model: needs ~${need}GB free, have ${free_gb}GB"
      continue
    fi
    echo "pulling: $model"
    if ! ollama pull "$model"; then
      warn "pull failed for $model (no such tag, network, or disk). Trying a smaller size."
      continue
    fi
  else
    echo "already installed: $model"
  fi

  if [ "$SKIP_CHECK" -eq 1 ] || [ "$gpu_expected" -eq 0 ]; then
    chosen="$model"; break
  fi

  echo "checking GPU use for $model ..."
  if gpu_ok "$model"; then
    echo "  GPU check passed (100% GPU)"
    chosen="$model"; break
  fi
  warn "$model does not run fully on GPU (too big for free memory). Trying a smaller size."
  ollama stop "$model" >/dev/null 2>&1 || true
done

[ -n "$chosen" ] || die "no model for family '$FAMILY' pulled and ran on GPU. Free memory (close apps) or use -k to skip the GPU check"

curl -fsS -m 5 "$OLLAMA_URL/api/tags" | grep -q "\"$chosen\"" \
  || warn "$chosen not listed by server; check 'ollama list'"

tmp=$(mktemp "${TMPDIR:-/tmp}/model.XXXXXX")
echo "$chosen" > "$tmp" && mv "$tmp" .model
echo "done. model: $chosen (saved to .model)"
