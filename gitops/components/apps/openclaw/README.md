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

## Changing the config

The init container copies `openclaw.json` and `AGENTS.md` to the PVC only if they are missing, so edits made
through OpenClaw survive restarts. To apply a ConfigMap change, delete the persisted copy and restart:

```bash
oc exec -n openclaw deploy/openclaw -- rm /home/node/.openclaw/openclaw.json
oc rollout restart -n openclaw deploy/openclaw
```

## Upgrading

Bump the pinned image tag in `base/deployment.yaml`.
