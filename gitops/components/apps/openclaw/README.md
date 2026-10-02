# OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) AI assistant gateway. The base is adapted from upstream's
`scripts/k8s/manifests`, with these OpenShift changes:

- `openclaw` ServiceAccount bound to the `nonroot-v2` SCC (the image runs as UID 1000)
- Edge-terminated Route in front of the gateway (port 18789), using the default wildcard ingress cert
- Gateway bound to `lan` so the router can reach it; token auth stays enabled

The `openclaw-config` ConfigMap and the `openclaw-secrets` ExternalSecret live in the cluster overlay
(`gitops/clusters/<cluster>/apps/openclaw/`) because they carry the cluster's public origin and Vault path.

## Prerequisites

Store the secrets in the cluster's Vault before syncing (property names are the env var names):

```bash
vault kv put secret/openclaw/secrets \
  OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)" \
  ANTHROPIC_API_KEY="..."
```

`OPENCLAW_GATEWAY_TOKEN` is required. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` and
`OPENROUTER_API_KEY` are optional; add whichever providers you use.

`HA_MCP_URL` (the Home Assistant MCP endpoint, `https://<ha-host>/api/mcp`) and `HA_TOKEN` (a Home Assistant
long-lived access token) configure the `homeassistant` MCP server in the simpsons `mcp.json5`. Both live in
Vault so the endpoint stays out of git. The simpsons overlay (`patch-ha-env.yaml`) makes them required: an unset
`HA_MCP_URL` would make `openclaw.json` invalid, so the container refuses to start until both keys exist:

```bash
vault kv patch secret/openclaw/secrets HA_MCP_URL="https://<ha-host>/api/mcp" HA_TOKEN="..."
```

## Changing the config

The config is split between the PVC and git:

| What | Owner | How changes apply |
| --- | --- | --- |
| `agents.json5` (agents, per-agent tools) and `mcp.json5` (MCP servers) | Git | Mounted read-only at `/config-git` and pulled into `openclaw.json` with `$include`. Edit the ConfigMap, then `oc rollout restart -n openclaw deploy/openclaw` |
| Everything else in `openclaw.json` (gateway, channels, ...) | PVC | Seeded once; change it through OpenClaw (CLI, Control UI) |
| Agent workspace files (`AGENTS.md`, `<agent-id>__<FILE>` keys) | PVC | Seeded once into `workspace/` or `workspace-<agent-id>/` |

Because the git-owned sections are read-only, OpenClaw refuses to write to them (`openclaw mcp add`,
`agents add`, the Control UI MCP editor) and leaves `openclaw.json` untouched. Change agents and MCP servers
through a PR instead.

To reapply a seed-only file, delete the persisted copy and restart:

```bash
oc exec -n openclaw deploy/openclaw -- rm /home/node/.openclaw/openclaw.json
oc rollout restart -n openclaw deploy/openclaw
```

## Agents

- `default`: general assistant; Home Assistant tools are denied
- `home-assistant`: talks to Home Assistant through the `homeassistant` MCP server; shell tools are denied so it
  cannot read `HA_TOKEN` from its environment

To add an agent, add it to `agents.json5` and seed its workspace with `<agent-id>__AGENTS.md` keys in the
ConfigMap.

## Home Assistant MCP

The `homeassistant` MCP server connects to Home Assistant's MCP Server integration at `HA_MCP_URL`
(Streamable HTTP, bearer token from `HA_TOKEN`). In Home Assistant, add the
**Model Context Protocol Server** integration and expose only the entities the agent should see
(Settings → Voice assistants → Expose).

Check the connection and the tools it provides:

```bash
oc exec -n openclaw deploy/openclaw -- openclaw mcp probe homeassistant
```

## Upgrading

Bump the pinned image tag in `base/deployment.yaml`.
