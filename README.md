# herdr-demo

Sandboxed AI coding agent: [herdr](https://github.com/creator-engine/herdr-ce) (terminal agent multiplexer) running GitHub Copilot CLI inside a locked-down container. The container has no direct internet. Its only exit is a Squid proxy that allows HTTPS to GitHub and Copilot domains.

```
sandbox --(internal net, no route out)--> egress-proxy (Squid, domain allowlist) --> GitHub / Copilot only
```

## Layout

- `docker-compose.yml`: `egress-proxy` (Squid) + `sandbox`
- `proxy/squid.conf`, `proxy/allowed-domains.txt`: the allowlist
- `Dockerfile`: Node 22, herdr, `@github/copilot`, non-root user
- `workspace/`: only host directory the agent can write

## Prereqs

- Podman (or Docker) with compose, already running
- An active Copilot seat. If the company manages Copilot, the org must enable the Copilot CLI policy.

## Run

```bash
./install.sh                        # creates workspace/, builds, starts, runs the isolation checks
podman compose exec -it sandbox herdr
```

`install.sh` options: `--rebuild` (no cache), `--verify` (checks only), `--down` (stop containers). It auto-detects podman, then docker; override with `COMPOSE="docker compose"`.

In a herdr pane, run `copilot`, then `/login` and follow the device-flow prompts. The login is kept in the `agent-home` volume. Work happens in `/work` (your `workspace/`).

Optional PAT instead of `/login`: fine-grained token with **Copilot Requests**, owned by a personal account (not an organization). Pass it with `podman compose run -e COPILOT_GITHUB_TOKEN=... sandbox`. The agent can read it, so use a short-lived token. If your seat is through the company, use `/login`.

## Verify the sandbox

```bash
podman compose exec sandbox id                                            # non-root, uid 1000
podman compose exec sandbox curl -sS -m5 -I https://api.github.com        # works via proxy
podman compose exec sandbox curl -sS -m5 -I https://example.com           # must fail (403 from proxy)
podman compose exec sandbox curl -sS -m5 --noproxy '*' -I https://api.github.com   # must fail (no route)
podman compose exec sandbox ls ~/.ssh                                     # must not exist
```

## Company network that re-signs HTTPS (TLS inspection)

Symptom during build or in the sandbox: `curl: (60) SSL certificate problem` or `unable to get local issuer certificate`. Do not use `curl -k`; that turns off verification, including for `curl | sh` installers run as root. Trust the company root CA instead.

`install.sh` does it for you:

```bash
./install.sh --list-ca               # list certificate names in the macOS System keychain
./install.sh --ca "Zscaler"          # export matching root CA(s) to certs/corp-ca.crt, rebuild, start, verify
./install.sh --ca-file ~/corp-ca.pem # or use a PEM file from IT
```

Use your proxy vendor's cert name in place of `Zscaler`. If IT gives you a DER `.cer`, convert it: `openssl x509 -inform der -in file.cer -out file.pem`.

Files in `certs/*.crt` are installed into the image trust store and used by Node. They are git-ignored. Ask IT for the exact root CA file if unsure. If the podman machine's own image pulls fail with the same error, the VM needs the cert too (`podman machine ssh`, then add it under `/etc/pki/ca-trust/source/anchors/` and run `update-ca-trust`).

## Tune the allowlist

Watch what the proxy blocks while using Copilot:

```bash
podman compose logs -f egress-proxy | grep -E 'TCP_DENIED'
```

Add needed domains to `proxy/allowed-domains.txt`, then `podman compose restart egress-proxy`. The starting list follows GitHub's Copilot allowlist reference. Package registries (npm, PyPI) are commented out; enable only what the demo needs.

## Security notes

- Container isolation, not VM isolation: shared kernel inside the Podman/Docker VM. The VM is a boundary from macOS.
- Allowlisting `*.githubusercontent.com` and `github.com` lets the agent reach any public GitHub content. It cannot push anywhere without credentials, but treat anything it can read as reachable.
- Code context is sent to GitHub Copilot. Confirm that is approved for the repository contents.
- Review `git diff` on the host before running anything the agent wrote (hooks, Makefile, scripts). Commit and push from the host.
- `podman compose` may ignore some options (`read_only`, limits). Check with `podman inspect`.

## TODO before first build

- Confirm the herdr install command on herdr.dev; the URL in `Dockerfile` is unverified.
- Confirm Copilot CLI honors the proxy variables. `NODE_USE_ENV_PROXY=1` is set for Node's fetch; if requests fail, check the proxy log.
- Pin the base image digest, `@github/copilot` version and herdr version.
