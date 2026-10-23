#!/usr/bin/env bash
# pick-model.sh — pick the biggest model that fits this machine and pull it with native Ollama.
# Usage: ./pick-model.sh [family]   default family: qwen2.5-coder
# Override detected memory: RAM_GB=16 ./pick-model.sh
set -euo pipefail

FAMILY="${1:-qwen2.5-coder}"

# Memory budget in GB
if [ -n "${RAM_GB:-}" ]; then
  total=$RAM_GB
elif [ "$(uname)" = "Darwin" ]; then
  total=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
elif [ -r /proc/meminfo ]; then
  total=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo)
else
  echo "cannot detect RAM; set RAM_GB=<n>" >&2; exit 1
fi

vram_gb=0
if command -v nvidia-smi >/dev/null 2>&1; then
  mb=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | sort -nr | head -1 | tr -d ' ')
  vram_gb=$(( ${mb:-0} / 1024 ))
fi

if [ "$vram_gb" -gt 0 ]; then
  budget=$vram_gb;              src="NVIDIA VRAM"
elif [ "$(uname)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
  # Apple silicon unified memory: macOS GPU limit is ~65-75% of total
  budget=$(( total * 65 / 100 )); src="Apple unified memory (65% of ${total}GB)"
else
  budget=$(( total * 6 / 10 ));  src="RAM, CPU only"
fi

# Q4 weights + headroom for context/KV cache
if   [ "$budget" -ge 28 ]; then size="32b"
elif [ "$budget" -ge 14 ]; then size="14b"
elif [ "$budget" -ge 8  ]; then size="7b"
elif [ "$budget" -ge 4  ]; then size="3b"
elif [ "$budget" -ge 2  ]; then size="1.5b"
else                            size="0.5b"
fi

model="${FAMILY}:${size}"
echo "budget: ${budget}GB from ${src}"
echo "pulling: ${model}"

ollama pull "$model"
echo "$model" > .model
echo "done. model saved to .model"
