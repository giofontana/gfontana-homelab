# gfontana-homelab

GitOps repository for managing two bare-metal Red Hat OpenShift clusters using ArgoCD (OpenShift GitOps) with Kustomize.

## Clusters

| Cluster | Role | Description |
|---------|------|-------------|
| **simpsons** | Hub | Primary cluster running ACM, ArgoCD, NVIDIA GPU, ODF storage, full observability stack |
| **flanders** | Spoke | Managed cluster with LVMS and TrueNAS CSI storage, virtualization, and networking |

Both clusters run on Dell bare-metal servers with iDRAC out-of-band management.

## Architecture

The repository follows the **app-of-apps pattern** with ArgoCD. Infrastructure is organized by domain, and operator subscriptions are sourced from an external [gitops-catalog](https://github.com/giofontana/gitops-catalog) with cluster-specific overlays applied on top.

Two ArgoCD instances run on the simpsons cluster:
- `openshift-gitops` manages the simpsons cluster directly
- `argocd-flanders` manages the flanders cluster remotely

All ArgoCD Applications use `selfHeal: true` and sync from the `main` branch.

### Directory Layout

```
gfontana-homelab/
├── gitops/
│   ├── clusters/                    # Cluster-specific configuration
│   │   ├── simpsons/                # Hub cluster
│   │   │   ├── apps/               # Workloads (Frigate, VMs, VMware migration)
│   │   │   └── infra/              # Infrastructure by domain
│   │   │       ├── compute/        # Virtualization, GPU, NFD, node maintenance
│   │   │       ├── network/        # MetalLB, NMState, OVN config
│   │   │       ├── observability/  # COO, Loki logging, monitoring, ACM observability
│   │   │       ├── platform/       # ACM, ArgoCD, MTV, OpenShift AI, pipelines
│   │   │       ├── security/       # cert-manager, Vault, External Secrets, sealed-secrets, OAuth
│   │   │       └── storage/        # Local storage, ODF (Ceph)
│   │   └── flanders/               # Spoke cluster
│   │       ├── apps/               # Workloads (Frigate)
│   │       └── infra/              # Infrastructure by domain
│   │           ├── compute/        # Virtualization
│   │           ├── network/        # NMState, OVN config
│   │           ├── security/       # cert-manager, Vault, External Secrets, OAuth
│   │           └── storage/        # LVMS, TrueNAS CSI
│   └── components/                  # Reusable bases
│       ├── apps/                    # Application manifests (Frigate, vm-sample-acm)
│       └── infra/                   # Operator subscription bases, Vault Helm values and docs
├── governance/
│   └── policies/                    # ACM governance policies
└── scripts/
    ├── channels-updater/            # Operator channel version management
    ├── poweroff_cluster/            # Bare-metal cluster shutdown via iDRAC
    ├── poweron_cluster/             # Bare-metal cluster power-on via iDRAC
    └── sealed-secrets/              # Sealed-secrets key management
```

### Kustomize Layering

Each operator follows a consistent three-layer pattern:

1. **Component base** (`components/infra/<operator>/`) — references the external gitops-catalog for the operator Subscription
2. **Cluster operator overlay** (`clusters/<cluster>/infra/<domain>/<operator>/operator/`) — patches the subscription channel via `patch-version.yaml`
3. **Cluster instance** (`clusters/<cluster>/infra/<domain>/<operator>/instance/`) — cluster-specific operand/CR configuration
4. **Aggregate** — combines operator + instance, referenced by the app-of-apps ArgoCD Application

## Operators

| Operator | Channel | Simpsons | Flanders |
|----------|---------|:--------:|:--------:|
| Advanced Cluster Management | release-2.17 | x | |
| cert-manager | stable-v1 | x | x |
| Cluster Observability Operator | stable | x | |
| External Secrets Operator | stable-v1 | x | x |
| HashiCorp Vault (Helm chart) | 0.34.0 | x | x |
| Local Storage | stable | x | |
| LVMS Operator | — | | x |
| MetalLB | stable | x | |
| MTV Operator | release-v2.12 | x | |
| NMState | stable | x | x |
| Node Feature Discovery | stable | x | |
| Node Maintenance Operator | stable | x | |
| NVIDIA GPU Operator | stable | x | |
| OpenShift AI | stable-3.x | x | |
| OpenShift Data Foundation | stable-4.22 | x | |
| OpenShift GitOps | latest | x | |
| OpenShift Logging/Loki | stable-6.6 | x | |
| OpenShift Pipelines | latest | x | |
| OpenShift Virtualization | stable | x | x |
| Sealed Secrets (legacy) | — | x | |
| TrueNAS CSI | stable | | x |

## Workloads

- **Frigate** — NVR with AI object detection, deployed with CPU or NVIDIA GPU overlay. NFS media storage, TLS via cert-manager/Let's Encrypt. See [Frigate README](gitops/components/apps/frigate/README.md).
- **vm-sample-acm** — Sample VM deployed via ACM ApplicationSet with Placement-based scheduling
- **VMware resources** — ESXi VM definitions for MTV migration

## Security

- **TLS**: cert-manager with Let's Encrypt production (Cloudflare DNS-01 challenge) for wildcard certificates
- **Secrets**: HashiCorp Vault (one per cluster) as the source of truth, synced into Kubernetes Secrets by the External Secrets Operator. Bitnami Sealed Secrets remains only for a few legacy secrets
- **OAuth**: GitHub and htpasswd identity providers, kubeadmin removal
- **RBAC**: Cluster-admin bindings managed via ACM governance policy

## Governance Policies (ACM)

| Policy | Scope | Description |
|--------|-------|-------------|
| cluster-admin-permission | All clusters | Enforces cluster-admin bindings |
| etcd-backup | Local cluster | Automated etcd backups every 6 hours (retains 5) |
| ingress-cert | prod/dev clusters | cert-manager + Let's Encrypt + wildcard cert on IngressController |
| policy-htpass | Local cluster | htpasswd OAuth for HyperShift HostedClusters |

## Network

- MetalLB IP pool: `192.168.101.100-192.168.101.150` (VLAN 101)
- OVN bridge mappings with VLAN trunk support (NMState NodeNetworkConfigurationPolicy)
- Network Attachment Definitions for localnet trunk and VLAN 102

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/poweroff_cluster/` | Graceful bare-metal cluster shutdown (drain nodes, iDRAC Redfish shutdown) |
| `scripts/poweron_cluster/` | Bare-metal cluster power-on (iDRAC Redfish, wait for API, uncordon) |
| `scripts/channels-updater/` | Bulk update operator subscription channels from `operators-channels.in` |
| `scripts/sealed-secrets/` | Extract and replace sealed-secrets keys |

## Making Changes

1. Edit manifests in the appropriate cluster overlay or component
2. Commit and push to the `main` branch
3. ArgoCD auto-syncs changes to the clusters

### Updating Operator Versions

1. Run `scripts/channels-updater/get-channels.sh` to get current operators versions
2. Edit operators file with the desired channels, then run:

```bash
./scripts/channels-updater/update-channels.sh
```

This updates all `patch-version.yaml` files across the tree.

### Managing Secrets

Secrets are stored in HashiCorp Vault and pulled into the cluster by the External Secrets Operator (ESO). Git only contains `ExternalSecret` manifests, never secret values.

```
Vault (secret/ KV v2, per cluster)
  └─> ClusterSecretStore "vault-backend" (Kubernetes auth, role external-secrets)
        └─> ExternalSecret (*-vault.yaml, in the app namespace)
              └─> Kubernetes Secret (created and refreshed by ESO)
```

| Cluster | Vault UI |
|---------|----------|
| simpsons | https://vault-ui-vault.apps.simpsons.lab.gfontana.me |
| flanders | https://vault-ui-vault.apps.flanders.lab.gfontana.me |

Vault runs in standalone mode with file storage and is **not auto-unsealed** — unseal it after every Vault pod restart.

**1. Store the secret in Vault** (UI, or CLI from the Vault pod):

```bash
oc exec -n vault hashicorp-vault-0 -- env VAULT_TOKEN=<token> \
  vault kv put secret/myapp/config api-key=<value>
```

**2. Add an `ExternalSecret`** as `<name>-vault.yaml` next to the consuming manifests and list it in `kustomization.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-config
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: myapp-config
    creationPolicy: Owner
  data:
    - secretKey: api-key          # key in the Kubernetes Secret
      remoteRef:
        key: myapp/config         # path under secret/
        property: api-key         # key inside the Vault entry
```

**3. Verify** after ArgoCD syncs:

```bash
oc get externalsecret myapp-config -n myapp   # STATUS=SecretSynced, READY=True
```

Further docs:
- [Vault & ESO installation](gitops/components/infra/vault/01-vault-and-eso-installation.md)
- [Using Vault with ESO](gitops/components/infra/vault/02-using-vault-with-eso.md)
- [One-time Vault Kubernetes auth setup per cluster](gitops/clusters/simpsons/infra/security/external-secrets-operator/README.md)

#### Legacy: Sealed Secrets

A few older secrets (OAuth, the `argocd-flanders` cluster secret, the flanders Frigate config) are still Bitnami sealed secrets. New secrets should use Vault; migrate these when you touch them.

```bash
kubectl create secret generic my-secret \
  --from-literal=key=value \
  --dry-run=client -o yaml | kubeseal --format=yaml > my-secret-sealed.yaml
```

Only `*-sealed.yaml` and `*-sealed-secret.yaml` files are tracked in Git. Plaintext secret files are gitignored.
