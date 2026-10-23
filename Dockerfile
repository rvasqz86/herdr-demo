FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git ca-certificates nodejs npm \
 && rm -rf /var/lib/apt/lists/*

# herdr: verify install command on herdr.dev before building
RUN curl -fsSL https://herdr.dev/install.sh | sh

# agent CLI that accepts custom OpenAI-compatible endpoint
RUN npm install -g opencode-ai

RUN useradd -m -u 1000 agent
USER agent
WORKDIR /work

CMD ["sleep", "infinity"]
