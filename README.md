# herdr-demo

Sandboxed AI coding agent environment: [herdr](https://github.com/creator-engine/herdr-ce) (terminal agent multiplexer) + local model via Ollama. Agent container has no internet; it can reach only the Ollama container.

## Layout

- `docker-compose.yml` — `ollama` (GPU, internet for model pull) + `sandbox` (internal network only)
- `Dockerfile` — sandbox image: herdr + opencode, non-root user
- `pick-model.sh` — detect free VRAM (or RAM) and pull the biggest fitting model
- `workspace/` — only directory the agent can write

## Prereqs

- Docker or rootless Podman with compose (`podman compose`)
- NVIDIA GPU: container toolkit (Docker) or CDI (Podman). No GPU: delete the `deploy:` block in compose.

## Run

```bash
mkdir -p workspace
docker compose up -d --build
./pick-model.sh                      # pulls e.g. qwen2.5-coder:14b
docker compose exec -it sandbox herdr
```

Detach herdr; agents keep running. Reattach with the same `exec` command.

## Verify sandbox

```bash
docker compose exec sandbox id                                   # non-root
docker compose exec sandbox curl -m3 https://example.com         # must fail
docker compose exec sandbox ls ~/.ssh                            # must not exist
docker inspect $(docker compose ps -q sandbox) | grep -iE 'CapDrop|ReadonlyRootfs'
```

## Security notes

- Container isolation, not VM isolation: shared host kernel. For untrusted code use a microVM runtime (`krun`, `runsc`) or Docker `sbx`.
- Sandbox can reach the full Ollama API, not just `/v1`. Put an nginx proxy exposing only `/v1/*` in front for tighter control.
- Review `git diff` on the host before running anything the agent wrote (hooks, Makefile, scripts).
- Compose `deploy:`, `read_only`, and tmpfs options may be ignored by `podman compose`; check with `podman inspect`.

## TODO before first build

- Confirm herdr install command on herdr.dev; the URL in `Dockerfile` is unverified.
- Confirm the `opencode-ai` npm package name.
- Pin base image digest and tool versions.
- `pick-model.sh` calls `docker compose`; swap to `podman compose` for Podman.
