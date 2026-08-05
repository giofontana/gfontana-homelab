# Using HashiCorp Vault with External Secrets Operator

This guide explains how to store secrets in Vault and have them automatically synced into Kubernetes Secrets via the External Secrets Operator (ESO).

## Prerequisites

- HashiCorp Vault installed and running (see `01-vault-and-eso-installation.md`)
- ESO installed with a `ClusterSecretStore` named `vault-backend` in `Valid/Ready` state

## How It Works

```
Vault (source of truth)
  └─> ClusterSecretStore (connection config)
        └─> ExternalSecret (per-namespace sync rule)
              └─> Kubernetes Secret (auto-created, auto-refreshed)
                    └─> Pod (uses it via envFrom/volumeMount as usual)
```

1. You store secrets in Vault (via UI or CLI)
2. You create an `ExternalSecret` CR in the target namespace
3. ESO reads from Vault and creates/updates a native Kubernetes Secret
4. Your pods consume it via `envFrom` or volume mounts — no app changes needed

## Step-by-Step: Syncing a Vault Secret to a Kubernetes Secret

### 1. Store the secret in Vault

**Via UI:**
1. Login to Vault UI → go to **secret/** → **Create secret**
2. Set the path (e.g. `myapp/config`)
3. Add key/value pairs (e.g. `db_password` = `s3cret`)
4. Save

**Via CLI:**
```bash
oc exec -n vault vault-0 -- vault kv put secret/myapp/config \
    db_password=s3cret \
    api_key=abc123
```

### 2. Create an ExternalSecret in your namespace

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-config
  namespace: myapp
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-config          # name of the K8s Secret to create
    creationPolicy: Owner       # ESO owns and manages the Secret lifecycle
  data:
    - secretKey: db_password    # key in the K8s Secret
      remoteRef:
        key: myapp/config       # path in Vault (under secret/)
        property: db_password   # key within the Vault secret
    - secretKey: api_key
      remoteRef:
        key: myapp/config
        property: api_key
```

### 3. Verify the sync

```bash
# Check ExternalSecret status
oc get externalsecret myapp-config -n myapp

# Expected: STATUS=SecretSynced, READY=True

# Check the created K8s Secret
oc get secret myapp-config -n myapp -o jsonpath='{.data}' | python3 -c "
import json,sys,base64
for k,v in json.load(sys.stdin).items(): print(f'{k}={base64.b64decode(v).decode()}')"
```

### 4. Use it in your deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    spec:
      containers:
        - name: myapp
          envFrom:
            - secretRef:
                name: myapp-config
```

No sidecar, no entrypoint changes, no file sourcing — it's a regular Kubernetes Secret.

## Syncing All Keys from a Vault Path

Instead of listing each key individually, use `dataFrom` to sync everything:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-config
  namespace: myapp
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-config
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: myapp/config
```

This creates a K8s Secret with one key per Vault key — no need to enumerate them.

## Automatic Refresh

The `refreshInterval` (default `1m`) controls how often ESO polls Vault. When a value changes in Vault, the K8s Secret is updated on the next poll. Pods using `envFrom` need a restart to pick up the new values (this is standard Kubernetes behavior).

To force an immediate sync:

```bash
oc annotate externalsecret myapp-config -n myapp reconcile=$(date +%s) --overwrite
```

## Real Example: smart-travel-buddy/api-keys

This is how the `api-keys` secret was configured for the Smart Travel Buddy app:

**Vault path:** `secret/smart-travel-buddy/api-keys`
**Keys:** `llm-api-key`, `openweathermap`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: api-keys
  namespace: smart-travel-buddy
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: api-keys-vault
    creationPolicy: Owner
  data:
    - secretKey: llm-api-key
      remoteRef:
        key: smart-travel-buddy/api-keys
        property: llm-api-key
    - secretKey: openweathermap
      remoteRef:
        key: smart-travel-buddy/api-keys
        property: openweathermap
```

## Key Concepts

| Concept | Description |
|---|---|
| **ClusterSecretStore** | Cluster-wide connection to Vault. Created once, used by any namespace. |
| **SecretStore** | Namespace-scoped alternative to ClusterSecretStore. Use when different namespaces need different Vault paths or credentials. |
| **ExternalSecret** | Declares which Vault secrets to sync and where. Creates/manages a K8s Secret in the same namespace. |
| **refreshInterval** | How often ESO polls Vault for changes. Lower = fresher but more Vault API calls. |
| **creationPolicy: Owner** | ESO creates and owns the Secret. Deleting the ExternalSecret deletes the Secret. |
| **creationPolicy: Merge** | ESO updates an existing Secret without owning it. Useful for adding Vault-managed keys to a Secret that also has static keys. |

## Vault Agent Injector vs ESO — When to Use Which

| | Vault Agent Injector | ESO |
|---|---|---|
| **How secrets reach the pod** | Sidecar writes files to `/vault/secrets/` | Creates a native K8s Secret |
| **App changes needed** | Must read files or source them at startup | None — uses standard `envFrom`/`volumeMount` |
| **Extra containers** | Yes (init + sidecar per pod) | No |
| **Best for** | Apps that already read config from files, or need dynamic secret renewal within the pod | Apps that consume env vars or need drop-in replacement for existing K8s Secrets |
