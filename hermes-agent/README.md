# hermes-agent

Hermes Agent gateway (Nous Research) on Kubernetes: Telegram chat frontend,
`opencode-go` LLM backend (`muse-spark-1.3-contributor` by default), and the
web dashboard behind ingress with login/password auth.

## What runs here

- Official image `nousresearch/hermes-agent:v0.22.1`, args `gateway run`
  (Telegram **polling** — no inbound connectivity needed for chat).
- `HERMES_DASHBOARD=1` runs the dashboard (port `9119`) as a supervised
  side-process in the same container; ingress exposes it.
- `/opt/data` (`HERMES_HOME`: sessions, memory, `state.db`, skills) persists
  on a 5Gi `local-path` PVC. `replicaCount` must stay `1`: one Telegram
  poller, one SQLite writer; `strategy: Recreate` enforces no overlap.

## Auth: yes, login/pass — with a caveat

The dashboard gate engages automatically on the container's non-loopback
bind (`0.0.0.0:9119`). Credentials come from the Secret:

- `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`
  (or `_PASSWORD_HASH`, scrypt — preferred, no plaintext at rest)
- `HERMES_DASHBOARD_BASIC_AUTH_SECRET` (session signing; stable value keeps
  logins alive across restarts)

Without a registered provider the dashboard **fails closed at startup**.
The username/password provider is for **trusted networks/VPN only** — never
expose it directly to the open internet, so restrict the ingress (see the
`whitelist-source-range` example in `values.yaml`, or Cloudflare Access).
For public-internet exposure use the Nous Portal OAuth provider
(`hermes dashboard register`) instead.

Two proxy details must be right, whichever restriction you choose:

- `hermes.trustedProxies` must list your ingress controller / pod CIDR. It
  gates `X-Forwarded-For` (per-client login rate limiting, meaningful auth
  audit IPs) **and** `X-Forwarded-Proto`, which is what marks the session
  cookies `Secure` behind the TLS terminator.
- `hermes.publicUrl` must be the exact external URL
  (`https://hermes.gambiarra.space`). It is accepted verbatim as the HTTP
  `Host` and WebSocket `Origin`, which is what lets the dashboard Chat
  terminal (PTY WebSocket) work through the ingress and the DNS-rebinding
  guard.

Verify the gate from any machine once deployed:

```
curl -s https://hermes.gambiarra.space/api/status | jq '.auth_required, .auth_providers'
# true
# ["basic"]
```

## Setup (order matters)

1. Push the `common-chart` 0.3.0 change to master first — the publish
   workflow ships it to GHCR. Until then `helm dependency build` and
   `scripts/verify-charts.sh` fail for this chart (`0.3.0: not found`).
2. `helm dependency update ./hermes-agent/` and commit the generated
   `Chart.lock` (pins the published digest, like every other consumer).
3. Telegram: message `@BotFather` → `/newbot` → save the token. Message
   `@userinfobot` → save your numeric user ID. (Optional, for groups:
   `/mybots` → Bot Settings → Group Privacy → off, then re-add the bot.)
4. OpenCode: subscribe at https://opencode.ai/auth → API key.
5. Create namespace + Secret (never commit values — file is gitignored):
   `kubectl create ns hermes-agent`
   `kubectl create secret generic hermes-agent-secrets -n hermes-agent ...`
   (full command in `secrets.yaml` header). `REPLACE_ME` placeholders are
   NOT validated — applying them unmodified sets the literal passwords.
6. Tune `values.yaml` (model, timezone, hostname, `trustedProxies`,
   ingress allowlisting) and verify:
   `helm template hermes-agent ./hermes-agent/`
7. Deploy via ArgoCD (temporary Application manifest, then delete the file),
   per `AGENTS.md`. The PVC carries `Prune=false` so uninstalls keep data.

## Reasoning level

`hermes.reasoningEffort` — currently **`xhigh`** (default was Hermes' `medium`).
Options: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra` —
`ultra` clamps to the strongest level the route accepts. Set it to `""` to go
back to Hermes' default. Verify the level actually applies after first deploy
(check `gateway.log`; a relay that rejects the field is retried without it).

- Persistent changes go through `values.yaml` + a `config-rev` bump. The
  read-only `config.yaml` mount blocks `hermes config set` and
  `/reasoning --global`, which write to that file.
- Session-only changes work live from Telegram or the dashboard Chat:
  `/reasoning high` (this session), `/reasoning show|hide` (thinking
  display), `/reasoning` (show current).
- Per-model levels aren't wired into the chart; if you need them, edit
  `templates/hermes-config.yaml` and add `agent.reasoning_overrides`.

## Changing Hermes config later

`hermes.*` values render into a subPath-mounted `config.yaml`, which
kubelet never updates in place — and ConfigMap edits don't restart pods.
After any `hermes.*` change, bump
`common-chart.podAnnotations["hermes-agent/config-rev"]` (`"1"` → `"2"` …)
in the same commit so the pod restarts onto the new file.

## MCP servers (n8n)

The gateway spawns stdio MCP servers as child processes; tools reach the
model as `mcp__<server>__<tool>` (e.g. `mcp__n8n_mcp__n8n_create_workflow`).
One is wired: `n8n-mcp` (`npx -y n8n-mcp`)
against the in-cluster Service `http://n8n-app.n8n.svc.cluster.local:80`.
Defined under `hermes.mcpServers` in `values.yaml`, rendered into
`mcp_servers:` in `config.yaml`.

- The n8n API key stays out of git: `config.yaml` carries `${N8N_API_KEY}`,
  which Hermes resolves from process env at config load — the
  `hermes-agent-secrets` Secret (`envFrom`), same pattern as the
  Telegram/OpenCode credentials. An unset var stays literal, so n8n API
  calls then fail with 401s: check the Secret first.
- `connectTimeout: 90` (Hermes default 30s) absorbs the cold `npx` download
  on first spawn; npm caches into `/opt/data/.npm` on the PVC (the image
  ships its own node/npx).
- n8n-mcp telemetry is opted out via `N8N_MCP_TELEMETRY_DISABLED=true`
  (env beats its on-disk config, so a fresh PVC stays opted out).
- Verify from the pod:
  `kubectl -n hermes-agent exec deploy/hermes-agent -- hermes mcp list` and
  `... -- hermes mcp test n8n-mcp`.
- Rotate the key in n8n (Settings → n8n API) → update the Secret
  (`kubectl -n hermes-agent patch secret hermes-agent-secrets --type merge
  -p '{"stringData":{"N8N_API_KEY":"..."}}'`) → restart the pod
  (`kubectl -n hermes-agent rollout restart deploy/hermes-agent`): env is
  read at container start, and `envFrom` changes alone don't restart pods.
- Adding another server: extend `hermes.mcpServers`, commit, and bump
  `config-rev` as usual.

## Conventions

- Full Hermes behavior config lives in `values.yaml` (`hermes.*` rendered
  into `config.yaml`); secrets only via the external Secret.
- `config.yaml` is mounted read-only: change it here in git, not in the
  dashboard Config page.
- No liveness probe by design (long agent turns); readiness on
  `GET /api/status`.
- Model ids verified with `opencode models`; live catalog at
  `https://opencode.ai/zen/go/v1/models`.
