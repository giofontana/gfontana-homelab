# AGENTS.md

Instructions for AI agents working on this repository.

## Repository Overview

This is a Kustomize-based GitOps repository managing two bare-metal Red Hat OpenShift clusters (**simpsons** and **flanders**) via ArgoCD with the app-of-apps pattern. Changes pushed to `main` are auto-synced by ArgoCD.

## Key Concepts

- **simpsons** is the hub cluster (runs ACM, ArgoCD, manages flanders)
- **flanders** is the spoke cluster (managed remotely by an ArgoCD instance on simpsons)
- Operator subscriptions are sourced from an external [gitops-catalog](https://github.com/giofontana/gitops-catalog) and overlaid with cluster-specific patches
- Secrets are encrypted with Bitnami Sealed Secrets — never commit plaintext secrets

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

- Never commit plaintext `*-secret.yaml` files (they are gitignored)
- Only `*-sealed.yaml` and `*-sealed-secret.yaml` are tracked
- Use `kubeseal` to encrypt secrets before committing

## ArgoCD Configuration

- All Applications use `selfHeal: true` and `prune: false`
- Source repository: `https://github.com/giofontana/gfontana-homelab.git`
- Target branch: `main`
- Simpsons apps deploy to `openshift-gitops` namespace
- Flanders apps deploy to `argocd-flanders` namespace with a cluster secret

## Kustomize Conventions

- All manifests use Kustomize (no Helm charts)
- Component bases reference the external gitops-catalog via remote URLs
- Cluster-specific patches are applied through overlays
- Sync waves are used to order resource creation (e.g., certificates before deployments)

## File Naming

- `kustomization.yaml` — Kustomize entry point
- `patch-version.yaml` — Operator subscription channel patch
- `*-sealed.yaml` — Sealed (encrypted) secrets safe for Git
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
