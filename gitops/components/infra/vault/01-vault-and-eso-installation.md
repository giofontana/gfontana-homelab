# HashiCorp Vault & External Secrets Operator — Installation Steps

Steps followed to install HashiCorp Vault and the External Secrets Operator (ESO) on the Simpsons OpenShift cluster (OCP 4.22.6).

## 1. Install HashiCorp Vault via Helm

### Add the Helm repo

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### Create the vault project

```bash
oc new-project vault
```

### Install Vault in dev mode with OpenShift overrides

```bash
helm install vault hashicorp/vault \
    --namespace vault \
    --set "global.openshift=true" \
    --set "server.dev.enabled=true" \
    --set "server.image.repository=docker.io/hashicorp/vault" \
    --set "injector.image.repository=docker.io/hashicorp/vault-k8s"
```

Key overrides:
- `global.openshift=true` — handles SCCs and OpenShift-specific configuration
- `server.dev.enabled=true` — runs Vault in dev mode (in-memory, auto-unsealed, root token = `root`)
- Image repository overrides ensure images are pulled from Docker Hub

### Verify pods

```bash
oc get pods -n vault
```

Expected: `vault-0` (1/1 Running) and `vault-agent-injector-*` (1/1 Running).

### Enable Kubernetes auth

```bash
oc exec -n vault vault-0 -- vault auth enable kubernetes

oc exec -n vault vault-0 -- sh -c \
  'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
```

### Expose the Vault UI

```bash
oc create route edge vault-ui --service=vault --port=8200 -n vault
```

Vault UI available at: `https://vault-ui-vault.apps.simpsons.lab.gfontana.me`
Login with method **Token**, value `root`.

> **Note:** Dev mode stores data in-memory. Data is lost on pod restart. For production, use integrated storage (Raft) with persistent volumes.

---

## 2. Install External Secrets Operator for Red Hat OpenShift

### Create the namespace, OperatorGroup, and Subscription

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: external-secrets-operator
  namespace: external-secrets-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: external-secrets-operator
  namespace: external-secrets-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-external-secrets-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Wait for the CSV to reach `Succeeded`:

```bash
oc get csv -n external-secrets-operator | grep external-secrets
```

### Create the operand (ExternalSecretsConfig)

This tells the operator to deploy the ESO pods in the `external-secrets` namespace:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ExternalSecretsConfig
metadata:
  name: cluster
spec:
  managementState: Managed
```

Wait for pods to come up:

```bash
oc get pods -n external-secrets
```

Expected: `external-secrets-*`, `external-secrets-cert-controller-*`, and `external-secrets-webhook-*` all Running.

---

## 3. Configure ESO to Connect to Vault

### Create a secret with the Vault token

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: external-secrets
type: Opaque
stringData:
  token: root
```

### Create a ClusterSecretStore

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          key: token
          namespace: external-secrets
```

### Add a NetworkPolicy to allow ESO to reach Vault

The Red Hat ESO operator creates a deny-all NetworkPolicy in the `external-secrets` namespace. You must explicitly allow egress to Vault:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-eso-to-vault
  namespace: external-secrets
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: external-secrets
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: vault
          podSelector:
            matchLabels:
              app.kubernetes.io/name: vault
      ports:
        - protocol: TCP
          port: 8200
```

### Verify

```bash
oc get clustersecretstore vault-backend
```

Expected: `STATUS: Valid`, `READY: True`.
