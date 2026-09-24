# AGENTS.md

Instructions for AI agents working on this repository.

## Repository Overview

This is a Kustomize-based GitOps repository managing two bare-metal Red Hat OpenShift clusters (**simpsons** and **flanders**) via ArgoCD with the app-of-apps pattern. Changes pushed to `main` are auto-synced by ArgoCD.

## Key Concepts

- **simpsons** is the hub cluster (runs ACM, ArgoCD, manages flanders)
- **flanders** is the spoke cluster (managed remotely by an ArgoCD instance on simpsons)
- Operator subscriptions are sourced from an external [gitops-catalog](https://github.com/giofontana/gitops-catalog) and overlaid with cluster-specific patches
- Secrets live in a per-cluster **HashiCorp Vault** and are synced into Kubernetes by the **External Secrets Operator (ESO)**. Git only holds `ExternalSecret` manifests — never commit plaintext secrets
- Bitnami Sealed Secrets is legacy: a few older secrets still use it, but new secrets must go through Vault

## Directory Conventions

```
gitops/components/          # Reusable bases (shared across clusters)
gitops/clusters/<cluster>/  # Cluster-specific overlays and instances
governance/policies/        # ACM governance policies
scripts/                    # Operational scripts (power management, secret handling)
```

### Operator Structure

Each operator follows this pattern under `gitops/clusters/<cluster>/infra/<domain>/<operator>/`:

```
<operator>/
├── operator/                # Subscription overlay
│   ├── kustomization.yaml   # References component base + applies patch
│   └── patch-version.yaml   # Patches the subscription channel
├── instance/                # Operand/CR configuration
│   └── kustomization.yaml
└── aggregate/               # Combines operator + instance
    └── kustomization.yaml
```

The aggregate is what ArgoCD Application manifests point to.

### App-of-Apps Structure

Each infrastructure domain has an `argocd-apps/` directory containing individual ArgoCD Application manifests. A top-level ArgoCD Application points to this directory, which in turn deploys all applications in that domain.

## Rules for Making Changes

### Adding a New Operator

1. Create a component base in `gitops/components/infra/<operator>/` referencing the gitops-catalog
2. Create the operator/instance/aggregate structure under the target cluster's infra domain
3. Create an ArgoCD Application manifest in the appropriate `argocd-apps/` directory
4. Add the operator to `scripts/channels-updater/operators-channels.in`

### Modifying an Existing Operator

- To change the operator channel: edit `patch-version.yaml` in the cluster's operator overlay
- To change the operand configuration: edit resources in the cluster's `instance/` directory
- To bulk-update channels: edit `operators-channels.in` and run `scripts/channels-updater/update-channels.sh`

### Adding a New Workload

1. Create reusable manifests in `gitops/components/apps/<workload>/` using base/overlay pattern
2. Create a cluster-specific overlay under `gitops/clusters/<cluster>/apps/<workload>/`
3. Add an ArgoCD Application manifest or reference it from an existing app-of-apps

### Secrets

Vault + ESO is the standard way to handle secrets. Each cluster runs its own Vault; there is no shared Vault between simpsons and flanders.

**How it is wired (per cluster):**

- Vault is deployed from the HashiCorp Helm chart by the `hashicorp-vault` ArgoCD Application (multi-source: chart + values from this repo)
  - Shared values: `gitops/components/infra/hashicorp-vault/values.yaml` (standalone mode, file storage on a 10Gi PVC, TLS disabled on the listener)
  - Cluster overrides: `gitops/clusters/<cluster>/infra/security/hashicorp-vault/helm/values.yaml`
  - `hashicorp-vault-config` Application deploys the `vault` namespace and the `vault-ui` Route (`hashicorp-vault/instance/`)
- ESO (Red Hat operator) lives under `gitops/clusters/<cluster>/infra/security/external-secrets-operator/`; its `instance/` holds:
  - `ClusterSecretStore` `vault-backend` → `http://hashicorp-vault.vault.svc:8200`, KV v2 engine mounted at `secret/`
  - Kubernetes auth with role `external-secrets`, using the `vault-auth` ServiceAccount in the `external-secrets` namespace
  - NetworkPolicy `allow-eso-to-vault` (the operator creates a deny-all policy, so egress to Vault on 8200 must be allowed explicitly)
- The Vault Kubernetes auth method, `external-secrets` policy and role are configured **manually** once per cluster — see `gitops/clusters/simpsons/infra/security/external-secrets-operator/README.md`
- Vault is not auto-unsealed: after a Vault pod restart it must be unsealed manually before ESO can sync again

**Adding a secret:**

1. Store the value in the target cluster's Vault under the KV v2 `secret/` mount, using `<namespace-or-app>/<secret-name>` as the path (e.g. `secret/cert-manager/cloudflare-api-token`). The user does this — agents must never write secret values into the repo
2. Add an `ExternalSecret` next to the consuming manifests, named `<secret-name>-vault.yaml`, and add it to the local `kustomization.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: truenas-api-credentials
  namespace: truenas-csi
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: truenas-api-credentials   # Kubernetes Secret ESO creates
    creationPolicy: Owner
  data:
    - secretKey: api-key             # key in the Kubernetes Secret
      remoteRef:
        key: truenas-csi/api-credentials   # path under secret/ (no "secret/" or "data/" prefix)
        property: api-key                  # key inside the Vault entry
```

- `secretKey` must match the key the consumer reads (e.g. the cert-manager ClusterIssuer reads `api-token`) — a mismatch fails silently at the consumer, not in ESO
- Use `refreshInterval: 1h` to match existing ExternalSecrets
- Existing examples: `cert-manager-operator/instance/cloudflare-api-token-vault.yaml` (both clusters), `flanders/infra/storage/truenas-csi/instance/truenas-api-credentials-vault.yaml`, `simpsons/apps/smart-travel-buddy/base/external-secret-api-keys.yaml`
- Usage guides: `gitops/components/infra/vault/02-using-vault-with-eso.md`

**Legacy Sealed Secrets:**

- Still used by: OAuth secrets (`infra/security/auth/*-sealed.yaml`), the `argocd-flanders` cluster secret, and the flanders Frigate config
- When touching one of these, prefer migrating it to Vault + ESO rather than re-sealing
- Never commit plaintext `*-secret.yaml` files (they are gitignored); only `*-sealed.yaml` and `*-sealed-secret.yaml` are tracked

## ArgoCD Configuration

- All Applications use `selfHeal: true` and `prune: false`
- Source repository: `https://github.com/giofontana/gfontana-homelab.git`
- Target branch: `main`
- Simpsons apps deploy to `openshift-gitops` namespace
- Flanders apps deploy to `argocd-flanders` namespace with a cluster secret

## Kustomize Conventions

- All manifests use Kustomize. The one exception is HashiCorp Vault, installed from its Helm chart via a multi-source ArgoCD Application
- Component bases reference the external gitops-catalog via remote URLs
- Cluster-specific patches are applied through overlays
- Sync waves are used to order resource creation (e.g., certificates before deployments)

## File Naming

- `kustomization.yaml` — Kustomize entry point
- `patch-version.yaml` — Operator subscription channel patch
- `*-vault.yaml` — `ExternalSecret` pulling a secret from Vault
- `*-sealed.yaml` — Legacy sealed (encrypted) secrets safe for Git
- `*-secret.yaml` — Plaintext secrets (gitignored, never commit)

## Testing Changes

This repository has no CI pipeline. Changes are validated by ArgoCD sync. After pushing:

1. Check ArgoCD UI for sync status and errors
2. Verify the operator/workload health in the OpenShift console
3. Check events and logs if sync fails

## Domain and Networking

- Domain: `gfontana.me` (Cloudflare DNS)
- TLS: cert-manager with Let's Encrypt production (DNS-01 via Cloudflare)
- MetalLB pool: `192.168.101.100-192.168.101.150`
- Host network: `192.168.101.x`, iDRAC management: `192.168.100.x`
