# Homelab monitoring

Metrics for homelab devices that live outside OpenShift, collected by a dedicated Prometheus (a Cluster Observability Operator `MonitoringStack`) on **flanders** and shown in Grafana.

- This component: the exporters and their ServiceMonitors.
- Cluster overlay (`gitops/clusters/flanders/infra/observability/`):
  - the `MonitoringStack`
  - `ScrapeConfig`s for devices Prometheus scrapes directly
  - ExternalSecrets
  - Grafana
  - persistence for the platform Prometheus

| Source | How | Job |
|---|---|---|
| Dell R630 iDRACs | `idrac_exporter` (Redfish), multi-target | `idrac` |
| UniFi | `unpoller` | `unpoller` |
| Pi-hole | `pihole-exporter` (Pi-hole v6 API) | `pihole-exporter` |
| TrueNAS | TrueNAS pushes Graphite to `graphite_exporter` on NodePort `32003` | `truenas-graphite-exporter` |
| Home Assistant | built-in `/api/prometheus` | `home-assistant` |
| LB VM | HAProxy prometheus-exporter `:8405`, node_exporter `:9100`, cloudflared `:2000` | `haproxy`, `node`, `cloudflared` |

Prometheus keeps 15 days on a 50Gi `truenas-iscsi` volume. Alertmanager is disabled.

## Setup

### 1. Secrets in flanders' Vault

| Path (under `secret/`) | Properties |
|---|---|
| `homelab-monitoring/idrac` | `username`, `password`: read-only Redfish user, the same on every iDRAC |
| `homelab-monitoring/unifi` | `url` (e.g. `https://192.168.1.1`), `username`, `password`: local read-only UniFi user |
| `homelab-monitoring/pihole` | `host` (IP or hostname), `password`: Pi-hole app password |
| `homelab-monitoring/home-assistant` | `token`: long-lived access token |
| `homelab-monitoring/grafana` | `session_secret`: e.g. `openssl rand -base64 32` |

### 2. DNS

Prometheus scrapes these names directly, so they must resolve from flanders pods (Pi-hole local DNS):

- `ha.gfontana.me`
- `lb.lab.gfontana.me`
- `idrac-bart.lab.gfontana.me`, `idrac-homer.lab.gfontana.me`, `idrac-marge.lab.gfontana.me`

Check from a pod (the idrac-exporter image is Alpine-based, so it has `nslookup`) with `oc -n homelab-monitoring exec deploy/idrac-exporter -- nslookup lb.lab.gfontana.me`, or from a node with `oc debug node/<node> -- chroot /host getent hosts lb.lab.gfontana.me`.

### 3. Devices

- **Home Assistant**: add `prometheus:` to `configuration.yaml` and restart.
- **LB VM**:
  - Expose HAProxy metrics:
    ```
    frontend prometheus
      bind :8405
      mode http
      http-request use-service prometheus-exporter if { path /metrics }
      no log
    ```
  - Install `node_exporter` (`:9100`).
  - Start cloudflared with `--metrics 0.0.0.0:2000`.
  - Allow ports 8405, 9100 and 2000 from the flanders nodes.
- **TrueNAS**: under Reporting → Exporters → Add (Graphite), set:
  - prefix `truenas`
  - destination `<any flanders node IP>`, port `32003`
  - a hostname of your choice (it becomes the `instance` label)
  - On TrueNAS 25.04+, also apply the `netdata.conf` from [truenas-graphite-to-prometheus](https://github.com/Supporterino/truenas-graphite-to-prometheus#truenas-scale) to restore the full metric set. It has to be reapplied after TrueNAS upgrades.

### 4. Bootstrap (once)

```bash
oc apply -f gitops/clusters/flanders/infra/observability/app-of-apps.yaml
```

## Access

- **Grafana:** https://grafana.apps.flanders.lab.gfontana.me (OpenShift login).
  - The `homelab` datasource (default) is this stack.
  - The `flanders` datasource is the cluster's own Thanos querier.
  - Dashboards are in the **Homelab** folder.
- **Prometheus:** no Route. Use `oc -n homelab-monitoring port-forward svc/homelab-prometheus 9090` and open http://localhost:9090/targets.

## Troubleshooting

- **A target is down:** check `/targets` first. DNS failures show as `no such host`.
- **Exporter pods won't start:** check `oc get externalsecrets -n homelab-monitoring`. Vault is not auto-unsealed, so after a Vault restart the Secrets stop refreshing until it is unsealed.
- **iDRAC scrapes:** these take tens of seconds (interval 2m, timeout 90s).
