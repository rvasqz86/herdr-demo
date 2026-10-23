#!/usr/bin/env bash
# Container entrypoint: install the baked herdr config into the (persistent) home volume on first
# start, then run the container command. Never blocks container start.
set -uo pipefail

SRC="${HERDR_CONFIG_SRC:-/opt/herdr-config}"
CFG="$HOME/.config/herdr"
DEFAULTS="${HERDR_DEMO_SHARE:-/usr/local/share/herdr-demo}"

# Seed only when no git checkout of the config exists yet. After that the checkout in the volume
# belongs to you: `git -C ~/.config/herdr pull` updates it. To re-seed from the image, delete
# ~/.config/herdr inside the container and restart it.
if [ -d "$SRC" ] && [ ! -d "$CFG/.git" ]; then
  mkdir -p "$HOME/.config"
  if [ -e "$CFG" ]; then
    mv "$CFG" "$CFG.orig.$(date +%s)"   # e.g. a default config herdr wrote earlier
  fi
  if cp -a "$SRC" "$CFG"; then
    rev=$(cut -c1-7 "$SRC.rev" 2>/dev/null || echo unknown)
    echo "sandbox: installed herdr config ($rev) to $CFG"
    # This image only ships copilot, so point every hq role at it unless a hq.local exists.
    [ -e "$CFG/hq.local" ] || cp "$DEFAULTS/hq.local" "$CFG/hq.local"
    "$CFG/bin/bootstrap" || echo "sandbox: bootstrap reported problems; config is installed, hq may need a manual run of $CFG/bin/bootstrap"
  else
    echo "sandbox: could not copy herdr config from $SRC" >&2
  fi
fi

exec "$@"
