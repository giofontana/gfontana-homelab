# Argo CD Agent hub (simpsons → ocp1, ocp2)

Pull-based Argo CD (argocd-agent, **managed mode**) for the HCP clusters `ocp1` and `ocp2`,
automated by ACM `GitOpsCluster` (`gitopsAddon` + `argoCDAgent`).

| Piece | Where |
|---|---|
| Principal (UI, no app-controller) | `ArgoCD argocd-hub` in ns `argocd-hub` |
| Cluster selection | `Placement argo-agent-placement` (`name In [ocp1, ocp2]`) |
| PKI, spoke operator + agent, cluster secrets | `GitOpsCluster argo-agent` (ACM generates `argocd-agent-*` secrets) |
| Cluster-scoped instance | `ARGOCD_CLUSTER_CONFIG_NAMESPACES` in `../openshift-gitops-operator/operator/patch-env.yaml` |

`openshift-gitops` (simpsons' own apps) is untouched and keeps working in push mode.

## Manual step (not in Git)

`openshift-gitops/argo-hub-placement` (push-mode GitOpsCluster `argo-hub`) lives only in the
cluster. Exclude the agent clusters from it so a cluster is never registered in both modes:

```bash
oc -n openshift-gitops patch placement argo-hub-placement --type=merge -p '{
  "spec": {"predicates": [{"requiredClusterSelector": {"labelSelector": {"matchExpressions": [
    {"key": "name", "operator": "NotIn", "values": ["ocp1", "ocp2"]}]}}}]}}'
```

Adding a cluster: add it to `placement.yaml` **and** to the `NotIn` list above.

## Deploying to an agent cluster

Create Applications in namespace `argocd-hub` with `spec.destination.name: <cluster>`
(see `examples/mario.yaml`). Managed mode: edits on the spoke are reverted.

## Verify

```bash
oc get argocd argocd-hub -n argocd-hub                      # Available
oc get gitopscluster argo-agent -n argocd-hub -o yaml        # all conditions True
oc get managedclusteraddon gitops-addon -n ocp1              # Available (same for ocp2)
oc get secret -n argocd-hub -l argocd.argoproj.io/secret-type=cluster
oc logs -n argocd-hub deploy/argocd-hub-agent-principal | grep -i agent
```

## Limitations (GitOps 1.22)

No pod logs / terminal from the hub UI, partial ApplicationSet support, limited app-of-apps in
managed mode, principal not HA.
