FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git ca-certificates gnupg bash \
 && rm -rf /var/lib/apt/lists/*

# Node 22+ is required by Copilot CLI (Ubuntu 24.04 apt ships an older Node)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# herdr: verify install command on herdr.dev before building
RUN curl -fsSL https://herdr.dev/install.sh | sh

# GitHub Copilot CLI (pin a version for demos: @github/copilot@<version>)
RUN npm install -g @github/copilot

# Non-root user. Home dir is created here so a named volume mounted on it inherits ownership.
RUN useradd -m -u 1000 agent && mkdir -p /work && chown agent:agent /work
USER agent
WORKDIR /work

CMD ["sleep", "infinity"]
