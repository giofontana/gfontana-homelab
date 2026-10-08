# KubeVirtBMC demo (simpsons)

A test VM (`bmc-test` in the `kubevirtbmc-demo` namespace) with a virtual BMC from [KubeVirtBMC](https://docs.kubevirtbmc.io/). The BMC exposes IPMI (623/UDP) and Redfish (80/TCP) on a MetalLB IP. The KubeVirtBMC controller is deployed by the `kubevirtbmc` app in `infra/compute`.

The VM uses `runStrategy: Manual`, so it only runs when the BMC powers it on. It has an empty CD-ROM drive (`cdrom`) where Redfish virtual media is hot-plugged. Its root disk (`bmc-test-rootdisk`, 30Gi) starts blank, so there is nothing to boot until you install an OS from an ISO.

## Prerequisites

- `ipmitool` and `curl` on your workstation (macOS: `brew install ipmitool`)
- The BMC credentials stored in simpsons Vault at `secret/kubevirtbmc-demo/bmc-test` (keys `username` and `password`). ESO syncs them into the `bmc-test-credentials` Secret.

Set up these variables first. The IP is assigned by MetalLB. `ipmi` is a shell function rather than a variable because zsh does not word-split `$VAR`. The block has no comments, so it pastes cleanly into interactive zsh.

```bash
BMC_IP=$(oc -n kubevirtbmc-demo get svc bmc-test-virtbmc \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
BMC_USER=$(oc -n kubevirtbmc-demo get secret bmc-test-credentials \
  -o jsonpath='{.data.username}' | base64 -d)
BMC_PASS=$(oc -n kubevirtbmc-demo get secret bmc-test-credentials \
  -o jsonpath='{.data.password}' | base64 -d)

ipmi() { ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" "$@"; }
REDFISH="http://$BMC_IP/redfish/v1"
```

## IPMI

### Check power state

```bash
ipmi power status
```

### 1. Power on

```bash
ipmi power on
```

Starts the VM. Check with `oc -n kubevirtbmc-demo get vmi bmc-test`.

### 2. Reset

```bash
ipmi power reset
```

Gracefully restarts the running VM. Use `ipmi power cycle` for a forced restart, with no grace period.

### 3. Power off

```bash
ipmi power off
```

Force-stops the VM immediately, like pulling the plug. Use `ipmi power soft` for a graceful (ACPI) shutdown.

## Redfish: boot the VM from an ISO

The Redfish system ID is `1`, the manager ID is `BMC`, and the virtual media slot is `CD1`.

### 1. Insert the ISO

```bash
curl -s -u "$BMC_USER:$BMC_PASS" -H 'Content-Type: application/json' -X POST \
  "$REDFISH/Managers/BMC/VirtualMedia/CD1/Actions/VirtualMedia.InsertMedia" \
  -d '{"Image": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-Live-44-1.7.x86_64.iso", "Inserted": true}'
```

KubeVirtBMC reads the ISO size and creates a CDI DataVolume named `bmc-test`. The DataVolume uses `ocs-storagecluster-ceph-rbd-virtualization` in Block mode, as set in the VirtualMachineBMC. KubeVirtBMC then hot-plugs the DataVolume into the `cdrom` drive.

The ISO is about 2.9 GB. Wait for the import to finish (`PHASE=Succeeded`) and check that the media shows `"Inserted": true` before booting:

```bash
oc -n kubevirtbmc-demo get dv bmc-test -w
curl -s -u "$BMC_USER:$BMC_PASS" "$REDFISH/Managers/BMC/VirtualMedia/CD1"
```

### 2. Set the boot device to CD

```bash
curl -s -u "$BMC_USER:$BMC_PASS" -H 'Content-Type: application/json' -X PATCH \
  "$REDFISH/Systems/1" \
  -d '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}'
```

`Once` boots from the ISO on the next start only. Use `Continuous` to keep booting from CD. The equivalent IPMI command is `ipmi chassis bootdev cdrom`.

### 3. Power on from the ISO

If the VM is off:

```bash
curl -s -u "$BMC_USER:$BMC_PASS" -H 'Content-Type: application/json' -X POST \
  "$REDFISH/Systems/1/Actions/ComputerSystem.Reset" -d '{"ResetType": "On"}'
```

If the VM is already running, restart it so it boots from the ISO:

```bash
curl -s -u "$BMC_USER:$BMC_PASS" -H 'Content-Type: application/json' -X POST \
  "$REDFISH/Systems/1/Actions/ComputerSystem.Reset" -d '{"ResetType": "ForceRestart"}'
```

Other `ResetType` values: `ForceOff`, `GracefulShutdown`, `GracefulRestart`.

Open the console to check that Fedora Live is booting:

```bash
virtctl vnc bmc-test -n kubevirtbmc-demo
```

You can also use **Virtualization → VirtualMachines → bmc-test → Console** in the OpenShift console.

### 4. Eject the ISO

```bash
curl -s -u "$BMC_USER:$BMC_PASS" -H 'Content-Type: application/json' -X POST \
  "$REDFISH/Managers/BMC/VirtualMedia/CD1/Actions/VirtualMedia.EjectMedia" -d '{}'
```

This detaches the volume from the VM and deletes the `bmc-test` DataVolume. Only one ISO can be inserted at a time, so eject before inserting a different image.

## Notes

- ArgoCD ignores the VM's power state, volumes, disks and interfaces (see `argocd-apps/kubevirtbmc-demo.yaml`). Without that, `selfHeal` would undo hot-plugged media and boot-order changes made through the BMC.
- The ISO URL must be reachable from the cluster over HTTP(S). The server must return `Content-Length` on a `HEAD` request, which the size check needs; redirects are followed. For internal HTTPS servers, set `spec.redfish.virtualMedia.tls` on the VirtualMachineBMC.
