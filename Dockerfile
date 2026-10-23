FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git ca-certificates gnupg bash \
 && rm -rf /var/lib/apt/lists/*

# Node 22+ is required by Copilot CLI (Ubuntu 24.04 apt ships an older Node)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
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

# Non-root user. Home dir is created here so a named volume mounted on it inherits ownership.
RUN useradd -m -u 1000 agent && mkdir -p /work && chown agent:agent /work
USER agent
WORKDIR /work

CMD ["sleep", "infinity"]
