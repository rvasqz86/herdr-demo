# Node 22 base from the registry: avoids NodeSource (apt repo) which fails on restricted/intercepted networks.
FROM node:22-bookworm-slim

# Fail the build if any command in a pipe fails (curl | sh must not hide a failed download)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git ca-certificates bash \
 && rm -rf /var/lib/apt/lists/*

# Optional company root CA(s): put *.crt files in certs/ (see README). Keeps TLS verification ON
# on networks that re-sign HTTPS traffic. With no certs this step is a no-op.
COPY certs/ /usr/local/share/ca-certificates/corp/
RUN update-ca-certificates
# Node ships its own CA bundle; point it at the system bundle that now includes the company CA.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# herdr: official install script puts the binary in ~/.local/bin of the installing user.
# Build runs as root, so move it onto the system PATH for the agent user. Fail loudly if missing.
RUN curl -fsSL https://herdr.dev/install.sh | sh \
 && for p in "$(command -v herdr || true)" /root/.local/bin/herdr /usr/local/bin/herdr; do \
      if [ -n "$p" ] && [ -x "$p" ]; then BIN="$p"; break; fi; \
    done \
 && test -n "${BIN:-}" \
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
