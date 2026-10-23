# herdr-demo

Sandboxed AI coding agent environment for macOS (Apple silicon): [herdr](https://github.com/creator-engine/herdr-ce) (terminal agent multiplexer) + local model via native Ollama. The agent container has no internet. Its only network path is an nginx proxy to the host Ollama `/v1/*` API.

## Layout

- `docker-compose.yml`: `model-proxy` (nginx, bridges to host Ollama) + `sandbox` (internal network only)
- `nginx.conf`: allows `/v1/*` only
- `Dockerfile`: sandbox image with herdr and opencode, non-root user
- `pick-model.sh`: picks model size from memory, pulls with native Ollama
- `workspace/`: only directory the agent can write

## Why Ollama is not in a container

Containers on macOS run in a Linux VM and cannot use the Apple GPU. Native Ollama uses Metal, which is much faster.

## Prereqs

- Ollama app installed on the Mac
- Docker Desktop, or Podman with `podman machine` and `podman compose`

## Run

```bash
ollama serve &                         # skip if the Ollama app is already running
./pick-model.sh                        # pulls e.g. qwen2.5-coder:14b
mkdir -p workspace
docker compose up -d --build           # or: podman compose up -d --build
docker compose exec -it sandbox herdr
```

`pick-model.sh` options: `-n` dry run, `-s 7b` force a size, `-f llama3.1` other family, `RAM_GB=16` override memory. It starts `ollama serve` if needed, checks disk space, and falls back to a smaller size if a pull fails.

If the proxy cannot reach Ollama (`502`), start Ollama with `OLLAMA_HOST=0.0.0.0 ollama serve`. This exposes it on your LAN, so enable the macOS firewall.

Detach herdr; agents keep running. Reattach with the same `exec` command.

## Verify sandbox

```bash
docker compose exec sandbox id                                          # non-root
docker compose exec sandbox curl -m3 https://example.com                # must fail
docker compose exec sandbox curl -m3 http://model-proxy:11434/v1/models # must work
docker compose exec sandbox curl -m3 http://model-proxy:11434/api/tags  # must be 403
docker compose exec sandbox ls ~/.ssh                                   # must not exist
```

## Security notes

- Container isolation, not VM isolation: shared kernel inside the Docker/Podman VM. The VM itself is a boundary from macOS, which helps.
- Review `git diff` on the host before running anything the agent wrote (hooks, Makefile, scripts).
- `podman compose` may ignore some options (`read_only`, tmpfs uid, limits). Check with `podman inspect`.

## TODO before first build

- Confirm herdr install command on herdr.dev; the URL in `Dockerfile` is unverified.
- Confirm the `opencode-ai` npm package name.
- Configure opencode to use `OPENAI_BASE_URL` and the model in `.model`.
- Pin base image digest and tool versions.
