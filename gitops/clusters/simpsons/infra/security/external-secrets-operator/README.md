# External Secrets Operator — Post-Deploy Manual Steps

After ArgoCD deploys the ESO operator and instance resources, the Vault Kubernetes auth role and policy must be configured manually. This is a one-time setup per cluster.

**Note:** Vault runs in dev mode (in-memory storage). These steps must be repeated after every Vault pod restart.

## Prerequisites

- Vault is running and accessible (`hashicorp-vault-0` pod in the `vault` namespace)
- The `vault-auth` ServiceAccount exists in the `external-secrets` namespace (created by ArgoCD)

## 1. Enable and configure Kubernetes auth in Vault

```bash
oc exec -n vault hashicorp-vault-0 -- vault auth enable kubernetes

oc exec -n vault hashicorp-vault-0 -- sh -c \
  'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
```

## 2. Create the Vault policy

Grants read access to all KV v2 secrets:

```bash
oc exec -n vault hashicorp-vault-0 -- vault policy write external-secrets - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
```

## 3. Create the Kubernetes auth role

Binds the `vault-auth` ServiceAccount to the `external-secrets` policy:

```bash
oc exec -n vault hashicorp-vault-0 -- vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=vault-auth \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=24h
```

## 4. Verify

Check the ClusterSecretStore is valid:

```bash
oc get clustersecretstore vault-backend
```

Expected: `STATUS: Valid`, `READY: True`.
