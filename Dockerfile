# Node 22 base from the registry: avoids NodeSource (apt repo) which fails on restricted/intercepted networks.
FROM node:22-bookworm-slim

# Fail the build if any command in a pipe fails (curl | sh must not hide a failed download)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git ca-certificates bash \
 && rm -rf /var/lib/apt/lists/*

# herdr: official install script puts the binary in ~/.local/bin of the installing user.
# Build runs as root, so move it onto the system PATH for the agent user. Fail loudly if missing.
RUN curl -fsSL https://herdr.dev/install.sh | sh \
 && BIN="$(command -v herdr || ls /root/.local/bin/herdr /usr/local/bin/herdr 2>/dev/null | head -1)" \
 && test -n "$BIN" \
 && { [ "$BIN" = /usr/local/bin/herdr ] || install -m 0755 "$BIN" /usr/local/bin/herdr; } \
 && test -x /usr/local/bin/herdr

# GitHub Copilot CLI (pin a version for demos: @github/copilot@<version>)
RUN npm install -g @github/copilot

# The node image ships a uid 1000 user named "node". Rename it to "agent" with home /home/agent
# so a named volume mounted there inherits the right ownership.
RUN groupmod -n agent node \
 && usermod -l agent -d /home/agent -m node \
 && mkdir -p /work && chown agent:agent /work
USER agent
WORKDIR /work

CMD ["sleep", "infinity"]
