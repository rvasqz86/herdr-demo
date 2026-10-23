# Node 22 base from the registry: avoids NodeSource (apt repo) which fails on restricted/intercepted networks.
FROM node:22-bookworm-slim

# Fail the build if any command in a pipe fails (curl | sh must not hide a failed download)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

# Core + common CLI tools from Debian. fd and bat get friendlier names below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl wget git ca-certificates bash ncurses-term \
      jq ripgrep fd-find fzf bat tree less nano htop procps file \
      unzip zip make \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && ln -s /usr/bin/batcat /usr/local/bin/bat \
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

# Neovim and lazygit: Debian's neovim is too old and lazygit is not packaged, so use release builds.
# TARGETARCH is set by buildx/podman (amd64 or arm64). Pin for demos: --build-arg LAZYGIT_VERSION=x.y.z
ARG TARGETARCH
ARG LAZYGIT_VERSION=
RUN case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) ARCH=x86_64 ;; \
      arm64) ARCH=arm64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${ARCH}.tar.gz" | tar -xz -C /opt \
 && ln -s "/opt/nvim-linux-${ARCH}/bin/nvim" /usr/local/bin/nvim \
 && LG="${LAZYGIT_VERSION:-$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/jesseduffield/lazygit/releases/latest | sed 's#.*/tag/v##')}" \
 && [[ "$LG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
 && curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LG}/lazygit_${LG}_Linux_${ARCH}.tar.gz" | tar -xz -C /usr/local/bin lazygit \
 && nvim --version | head -1 \
 && lazygit --version | head -1

# GitHub Copilot CLI (pin a version for demos: @github/copilot@<version>)
RUN npm install -g @github/copilot

# Bake the herdr config (keybindings, hq launcher, roles) into the image. It is public, so no
# credentials are needed. The entrypoint installs it into ~/.config/herdr on first start, because
# /home/agent is a persistent volume. Override: --build-arg HERDR_CONFIG_REPO=... HERDR_CONFIG_REF=<tag|branch>
ARG HERDR_CONFIG_REPO=https://github.com/rvasqz86/herdr-config.git
ARG HERDR_CONFIG_REF=
RUN git clone --depth 1 ${HERDR_CONFIG_REF:+--branch "$HERDR_CONFIG_REF"} "$HERDR_CONFIG_REPO" /opt/herdr-config \
 && git -C /opt/herdr-config rev-parse HEAD > /opt/herdr-config.rev \
 && chmod -R a+rX /opt/herdr-config /opt/herdr-config.rev \
 && test -x /opt/herdr-config/bin/bootstrap

COPY docker/hq.local /usr/local/share/herdr-demo/hq.local
COPY docker/entrypoint.sh /usr/local/bin/sandbox-entrypoint
RUN chmod 0755 /usr/local/bin/sandbox-entrypoint

# hq is linked into ~/.local/bin by the config's bootstrap script
ENV PATH="/home/agent/.local/bin:${PATH}"

# The node image ships a uid 1000 user named "node". Rename it to "agent" with home /home/agent
# so a named volume mounted there inherits the right ownership.
RUN groupmod -n agent node \
 && usermod -l agent -d /home/agent -m node \
 && mkdir -p /work && chown agent:agent /work
USER agent
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["sleep", "infinity"]
