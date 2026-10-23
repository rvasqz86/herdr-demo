#!/usr/bin/env bash
# pick-model.sh — detect VRAM (or RAM) and pull biggest fitting model into the ollama container.
# Usage: ./pick-model.sh [family]   default family: qwen2.5-coder
set -euo pipefail

FAMILY="${1:-qwen2.5-coder}"

# Free VRAM in GB (largest single GPU), else 0
vram_gb=0
if command -v nvidia-smi >/dev/null 2>&1; then
  mb=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | sort -nr | head -1 | tr -d ' ')
  vram_gb=$(( ${mb:-0} / 1024 ))
fi

# Available RAM in GB
ram_gb=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)

if [ "$vram_gb" -gt 0 ]; then
  budget=$vram_gb
  src="GPU VRAM"
else
  # CPU only: be conservative, leave RAM for OS + context
  budget=$(( ram_gb * 6 / 10 ))
  src="RAM (CPU only)"
fi

# Q4 weights + ~25% headroom for context/KV cache
if   [ "$budget" -ge 28 ]; then size="32b"
elif [ "$budget" -ge 14 ]; then size="14b"
elif [ "$budget" -ge 8  ]; then size="7b"
elif [ "$budget" -ge 4  ]; then size="3b"
elif [ "$budget" -ge 2  ]; then size="1.5b"
else                            size="0.5b"
fi

model="${FAMILY}:${size}"
echo "budget: ${budget}GB from ${src} (vram=${vram_gb}GB ram=${ram_gb}GB)"
echo "pulling: ${model}"

docker compose exec ollama ollama pull "$model"
echo "$model" > .model
echo "done. model saved to .model"
