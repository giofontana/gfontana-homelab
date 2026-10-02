# OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) AI assistant gateway. The base is adapted from upstream's
`scripts/k8s/manifests`, with these OpenShift changes:

- `openclaw` ServiceAccount bound to the `nonroot-v2` SCC (the image runs as UID 1000)
- Edge-terminated Route in front of the gateway (port 18789), using the default wildcard ingress cert
- Gateway bound to `lan` so the router can reach it; token auth stays enabled

Layout:

- `base/`: Deployment, PVC, Service, Route, ServiceAccount
- `config/`: Kustomize component with the config shared by every cluster: the `openclaw-config` ConfigMap
  (`agents.json5`, `mcp.json5`, workspace seeds) and the required Home Assistant env vars
- `gitops/clusters/<cluster>/apps/openclaw/`: the cluster overlay. It adds `openclaw.json` to the ConfigMap
  (`patch-openclaw-json.yaml`, which carries the Control UI origin), the Route host, and the `openclaw-secrets`
  ExternalSecret for that cluster's Vault

OpenClaw runs on simpsons and flanders with the same agents and MCP servers. Each cluster has its own Vault, PVC
and device pairings. flanders keeps its PVC on `truenas-iscsi` instead of the default LVMS class.

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
long-lived access token) configure the `homeassistant` MCP server in `config/configmap.yaml` (`mcp.json5`). Both live in
Vault so the endpoint stays out of git. `config/patch-ha-env.yaml` makes them required: an unset
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

To add an agent, add it to `agents.json5` and seed its workspace with `<agent-id>__<FILE>` keys in the
ConfigMap (`AGENTS.md`, `IDENTITY.md`, `SOUL.md`, ...). When a seeded `IDENTITY.md`, `SOUL.md` or `USER.md`
differs from OpenClaw's template, OpenClaw treats setup as complete and skips the `BOOTSTRAP.md` first-run
"who am I?" conversation.

Seeds only fill in missing files. To apply a changed seed to an existing workspace, delete that file and restart:

```bash
oc exec -n openclaw deploy/openclaw -- rm /home/node/.openclaw/workspace-<agent-id>/SOUL.md
oc rollout restart -n openclaw deploy/openclaw
```

## Private workspace files (Vault)

Workspace files that must not be public, such as a `TOOLS.md` with device names, live in Vault instead of git.
Each property of `secret/openclaw/workspace` is one file, named `<agent-id>__<FILE>`. The
`openclaw-workspace` ExternalSecret (`config/openclaw-workspace-vault.yaml`) syncs them into a Secret, and the
init container copies them into `~/.openclaw/workspace-<agent-id>/` on **every start**, overwriting the
workspace copy. Vault is the source of truth, so edits made in the workspace are lost on restart.

```bash
vault kv patch secret/openclaw/workspace home-assistant__TOOLS.md=@TOOLS.md
oc rollout restart -n openclaw deploy/openclaw
```

In the Vault UI, use the key/value view (not JSON mode) and paste the file as the value; newlines are kept.
Each cluster has its own Vault, so add it to every cluster that should have the file. Without the path, the pod
still starts (the Secret volume is optional), but the ExternalSecret reports a sync error. ESO refreshes hourly;
force a sync with `oc annotate externalsecrets.external-secrets.io -n openclaw openclaw-workspace force-sync=$(date +%s) --overwrite`.

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
