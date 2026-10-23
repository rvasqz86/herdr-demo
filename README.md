# herdr-demo

Sandboxed AI coding agent environment for Apple silicon: [herdr](https://github.com/creator-engine/herdr-ce) (terminal agent multiplexer) + local model on **native Ollama (Metal GPU)**. The agent container has no internet. Its only network path is an nginx proxy to the host's Ollama `/v1/*` API.

```
sandbox --(internal net, no internet)--> model-proxy (nginx, /v1/* only) --> host Ollama (Metal)
```

## Layout

- `docker-compose.yml`: `model-proxy` (nginx) + `sandbox` (internal network only)
- `nginx/default.conf.template`: allows `/v1/*` only; upstream set by `OLLAMA_UPSTREAM`
- `Dockerfile`: sandbox image with herdr and opencode, non-root user
- `pick-model.sh`: picks model size from unified memory, pulls with native Ollama
- `workspace/`: only directory the agent can write

## Why native Ollama

Containers on macOS run in a Linux VM with no access to the Apple GPU. Ollama in a container is CPU only and slow. Native Ollama uses Metal.

## Run (Podman)

```bash
brew install ollama podman podman-compose
podman machine start                       # if not already running
mkdir -p workspace
./pick-model.sh -w                         # starts Ollama, pulls a fitting model, warms it, shows GPU use
podman compose up -d --build
podman compose exec -it sandbox herdr
```

Docker Desktop instead: `export OLLAMA_UPSTREAM=http://host.docker.internal:11434` and use `docker compose`.

`pick-model.sh` options: `-n` dry run, `-s 7b` force size, `-f llama3.1` other family, `-w` warm up and show GPU use, `RAM_GB=16` override memory. It starts `ollama serve` with light settings (`KEEP_ALIVE=2m`, one parallel request, one loaded model) if Ollama is not running, checks disk, and falls back to a smaller size if a pull fails.

## If the proxy cannot reach Ollama (502)

Ollama listens on `127.0.0.1` by default. Podman and Docker usually forward `host.*.internal` to the Mac's loopback. If not, restart Ollama on all interfaces and enable the macOS firewall:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
```

## Verify

```bash
ollama ps                                                                # 100% GPU
podman compose exec sandbox id                                           # non-root
podman compose exec sandbox curl -m3 https://example.com                 # must fail
podman compose exec sandbox curl -m3 http://model-proxy:11434/v1/models  # must work
podman compose exec sandbox curl -m3 http://model-proxy:11434/api/tags   # must be 403
podman compose exec sandbox ls ~/.ssh                                    # must not exist
```

## Keep the Mac responsive

| Mac RAM | Comfortable model |
|---|---|
| 8GB | 1.5b to 3b |
| 16GB | 7b |
| 32GB | 14b |
| 64GB+ | 32b |

Keep agent context at 8k to 16k. Large context grows memory fast. Watch the Memory pressure graph in Activity Monitor; red means pick a smaller model.

## Security notes

- Container isolation, not VM isolation: shared kernel inside the Podman/Docker VM. The VM is a boundary from macOS.
- The proxy blocks pull, delete and create on the Ollama API, but host Ollama itself is reachable by anything else on the host.
- Review `git diff` on the host before running anything the agent wrote (hooks, Makefile, scripts).
- `podman compose` may ignore some options (`read_only`, tmpfs uid, limits). Check with `podman inspect`.

## TODO before first build

- Confirm herdr install command on herdr.dev; the URL in `Dockerfile` is unverified.
- Confirm the `opencode-ai` npm package name.
- Configure opencode to use `OPENAI_BASE_URL` and the model in `.model`.
- Pin base image digest and tool versions.
