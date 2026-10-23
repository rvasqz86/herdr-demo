# herdr-demo

Sandboxed AI coding agent environment: [herdr](https://github.com/creator-engine/herdr-ce) (terminal agent multiplexer) + local model via Ollama, all in containers.

```
sandbox  --(internal net, no internet)-->  model-proxy (nginx, /v1/* only)  -->  ollama  --(egress net)--> internet (model pull only)
```

## Layout

- `docker-compose.yml`: `ollama`, `model-proxy` (nginx), `sandbox`
- `nginx.conf`: allows `/v1/*` only, so the agent cannot pull, delete or create models
- `Dockerfile`: sandbox image with herdr and opencode, non-root user
- `pick-model.sh`: picks model size from available memory, pulls it into the Ollama container
- `workspace/`: only directory the agent can write

## macOS note (important)

Containers on macOS run in a Linux VM and cannot use the Apple GPU. Ollama in a container is CPU only, so tokens/sec is low. Give the VM enough memory and use a smaller model for demos. For GPU speed, run Ollama natively and use `./pick-model.sh -l` (then point the proxy at the host instead).

## Run (Podman)

```bash
brew install podman podman-compose
podman machine init --cpus 6 --memory 12288      # once; pick memory for the model you want
podman machine start
mkdir -p workspace
podman compose up -d --build
./pick-model.sh                                  # starts ollama container if needed, pulls a model
podman compose exec -it sandbox herdr
```

Change VM memory later: `podman machine stop && podman machine set --memory 16384 && podman machine start`.

Docker works too: replace `podman compose` with `docker compose`.

`pick-model.sh` options: `-n` dry run, `-s 7b` force size, `-f llama3.1` other family, `-l` host Ollama, `RAM_GB=16` override memory. It reads memory from inside the container (the VM), checks disk, and falls back to a smaller size if a pull fails.

## Verify sandbox

```bash
podman compose exec sandbox id                                           # non-root
podman compose exec sandbox curl -m3 https://example.com                 # must fail
podman compose exec sandbox curl -m3 http://model-proxy:11434/v1/models  # must work
podman compose exec sandbox curl -m3 http://model-proxy:11434/api/tags   # must be 403
podman compose exec sandbox curl -m3 http://ollama:11434/api/tags        # must fail (different network)
podman compose exec sandbox ls ~/.ssh                                    # must not exist
```

Networks: `sandbox` is only on `internal` with `model-proxy`. `ollama` is on `backend` (with `model-proxy`) and `egress` (internet). The sandbox cannot reach Ollama except through the `/v1/*` proxy.

## Security notes

- Container isolation, not VM isolation: shared kernel inside the Podman/Docker VM. The VM is a boundary from macOS.
- Review `git diff` on the host before running anything the agent wrote (hooks, Makefile, scripts).
- `podman compose` may ignore some options (`read_only`, tmpfs uid, limits). Check with `podman inspect`.

## TODO before first build

- Confirm herdr install command on herdr.dev; the URL in `Dockerfile` is unverified.
- Confirm the `opencode-ai` npm package name.
- Configure opencode to use `OPENAI_BASE_URL` and the model in `.model`.
- Pin base image digest and tool versions.
