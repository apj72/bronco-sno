# Bronco SNO Cluster Installation Guide

This document captures the full process for deploying the Bronco Single Node OpenShift (SNO) cluster on the `cars2.lab` environment using the assisted-service and ArgoCD from an ACM hub cluster.

## Environment Overview

| Component | Detail |
|-----------|--------|
| Hub cluster | m4.cars2.lab (OCP 4.18.15, 3-node compact) |
| Hub console | console-openshift-console.apps.m4.cars2.lab |
| Hub API | api.m4.cars2.lab:6443 |
| Hub cluster IP | 192.168.38.111 |
| Hub nodes | supervisor1 (.112), supervisor2 (.113), supervisor3 (.114) |
| Jump box (KVM host) | 192.168.38.31 (`ssh -A ajoyce@192.168.38.31`) |
| SNO target | Bronco (Dell R760, hostname: spr760-1.bronco.cars2.lab) |
| Bronco iDRAC | 192.168.38.208 |
| OCP version | 4.20.14 |
| Git repo | https://github.com/apj72/bronco-sno |
| Repo clone on jump box | `/local_home/ajoyce/bronco-sno` |

## Prerequisites

### Hub Cluster Operators

The following operators must be installed and in `Succeeded` state on the hub:

| Operator | Version (at time of install) |
|----------|------------------------------|
| Advanced Cluster Management (ACM) | 2.14.2 |
| Multicluster Engine (MCE) | 2.9.2 |
| OpenShift GitOps (ArgoCD) | 1.19.1 |
| Topology Aware Lifecycle Manager (TALM) | 4.18.3 |

Verify with:

```bash
oc get csv -n open-cluster-management | head -5
oc get csv -n multicluster-engine | head -5
oc get csv -n openshift-gitops | head -5
```

All should show `PHASE: Succeeded`.

### Assisted Service

The assisted-service must be running on the hub. It is deployed by creating an `AgentServiceConfig` CR.

Check if the assisted-service is running:

```bash
oc get pods -n multicluster-engine | grep assisted
```

If no pods are found, check for an `AgentServiceConfig`:

```bash
oc get agentserviceconfig
```

If missing, apply the one included in this repo:

```bash
oc apply -f 00-hub-prereqs/agentserviceconfig.yaml
```

This creates PVCs on the `lso-filesystemclass` storage class for the database, filesystem, and image storage. Ensure sufficient PVs are available:

```bash
oc get pv | grep Available
```

### RHCOS OS Images for Assisted Service

The assisted-service only ships with RHCOS images for the OCP versions it was built with (4.17-4.19 for MCE 2.9.2). To install OCP 4.20, add the RHCOS 4.20 image to the AgentServiceConfig:

```bash
oc patch agentserviceconfig agent --type=merge -p '{"spec":{"osImages":[{"openshiftVersion":"4.20","cpuArchitecture":"x86_64","url":"https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.20/latest/rhcos-4.20.11-x86_64-live-iso.x86_64.iso","version":"420.94.202502060915-0"}]}}'
```

The assisted-service pods will restart automatically. Verify with:

```bash
oc get pods -n multicluster-engine | grep assisted
```

### Bare Metal Operator: Watch All Namespaces

The metal3 bare metal operator must be configured to watch BMH resources in all namespaces (not just `openshift-machine-api`):

```bash
oc get provisioning -o jsonpath='{.items[0].spec.watchAllNamespaces}'
```

If empty or false, enable it:

```bash
oc patch provisioning provisioning-configuration --type=merge -p '{"spec":{"watchAllNamespaces":true}}'
```

### ArgoCD RBAC

The ArgoCD application controller service account needs cluster-admin permissions to create the required resources:

```bash
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

### Hub Memory and Disk Capacity

The m4 hub is a compact 3-node cluster with 100GB root disks. It can hit memory and disk pressure under load. If pods are stuck in `Pending` or getting evicted:

**Disable unnecessary MCE components to free memory:**

```bash
oc patch multiclusterengine multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift","enabled":false},{"name":"hypershift-local-hosting","enabled":false}]}}}'
```

**Clean up old audit logs to free disk:**

```bash
oc debug node/<nodename> -- chroot /host find /var/log/kube-apiserver -name "audit-*.log" -mtime +2 -delete 2>/dev/null
oc debug node/<nodename> -- chroot /host find /var/log/openshift-apiserver -name "audit-*.log" -mtime +7 -delete 2>/dev/null
oc debug node/<nodename> -- chroot /host find /var/log/oauth-apiserver -name "audit-*.log" -mtime +7 -delete 2>/dev/null
```

**Clean up failed/completed pods:**

```bash
oc delete pods -A --field-selector=status.phase=Succeeded
oc delete pods -A --field-selector=status.phase=Failed
```

**Check node conditions:**

```bash
oc get nodes -o custom-columns="NODE:.metadata.name,MEMORY:.status.conditions[?(@.type=='MemoryPressure')].status,DISK:.status.conditions[?(@.type=='DiskPressure')].status"
```

### DNS Records

The lab DNS server is **dnsmasq** running on `cars2-client` (`192.168.38.12`). DNS records for the bronco cluster must exist before the cluster can be accessed externally. The records are in `/etc/dnsmasq.d/dnsmasq.data312.conf`:

```
# Bronco SNO cluster DNS
domain=bronco.cars2.lab,192.168.38.145,192.168.38.145
dhcp-range= tag:bronco,192.168.38.145,192.168.38.145,3h
dhcp-option= tag:bronco,option:netmask,255.255.255.192
dhcp-option= tag:bronco,option:router,192.168.38.129
dhcp-option= tag:bronco,option:dns-server,192.168.38.12
dhcp-option= tag:bronco,option:domain-search,bronco.cars2.lab
dhcp-option= tag:bronco,option:ntp-server,192.168.38.12

# API (IPv4 + IPv6)
address=/api.bronco.cars2.lab/192.168.38.145
address=/api.bronco.cars2.lab/2600:52:7:300::145
ptr-record=145.38.168.192.in-addr.arpa,api.bronco.cars2.lab
ptr-record=5.4.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.3.0.7.0.0.0.2.5.0.0.0.0.6.2.ip6.arpa,api.bronco.cars2.lab

# Wildcard apps (IPv4 + IPv6)
address=/.apps.bronco.cars2.lab/192.168.38.145
address=/.apps.bronco.cars2.lab/2600:52:7:300::145

# Node hostname
dhcp-host=ec:2a:72:51:31:b8,192.168.38.145,spr760-1.bronco.cars2.lab, set:bronco
address=/spr760-1.bronco.cars2.lab/192.168.38.145
address=/spr760-1.bronco.cars2.lab/2600:52:7:300::145
ptr-record=145.38.168.192.in-addr.arpa,spr760-1.bronco.cars2.lab
ptr-record=5.4.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.3.0.7.0.0.0.2.5.0.0.0.0.6.2.ip6.arpa,spr760-1.bronco.cars2.lab
```

After adding or modifying records, restart dnsmasq:

```bash
sudo systemctl restart dnsmasq
```

Verify from the KVM host:

```bash
dig api.bronco.cars2.lab @192.168.38.12
dig console-openshift-console.apps.bronco.cars2.lab @192.168.38.12
```

Both should return `192.168.38.145`.

**Note:** These DNS records are **not** created by the OpenShift installer. They are a manual prerequisite managed on the lab DNS server.

#### Adding DNS records for a new SNO cluster

To add a new SNO cluster to the lab DNS, SSH to the DNS server and edit the dnsmasq config:

```bash
ssh ajoyce@192.168.38.12
sudo vi /etc/dnsmasq.d/dnsmasq.data312.conf
```

Add the following block, replacing the placeholder values:

- `CLUSTERNAME` -- the cluster name (e.g. `bronco`)
- `NODE_MAC` -- the boot interface MAC address
- `NODE_HOSTNAME` -- the node FQDN (e.g. `spr760-1.bronco.cars2.lab`)
- `IPV4` -- the node's IPv4 address (e.g. `192.168.38.145`)
- `IPV6` -- the node's IPv6 address (e.g. `2600:52:7:300::145`)
- `IPV4_REVERSE` -- the reversed IPv4 octets (e.g. `145.38.168.192`)
- `IPV6_REVERSE` -- the fully expanded reversed IPv6 nibbles (see below)
- `NETMASK` -- the subnet mask (e.g. `255.255.255.192`)
- `GATEWAY` -- the default gateway (e.g. `192.168.38.129`)

```
# CLUSTERNAME SNO cluster DNS
domain=CLUSTERNAME.cars2.lab,IPV4,IPV4
dhcp-range= tag:CLUSTERNAME,IPV4,IPV4,3h
dhcp-option= tag:CLUSTERNAME,option:netmask,NETMASK
dhcp-option= tag:CLUSTERNAME,option:router,GATEWAY
dhcp-option= tag:CLUSTERNAME,option:dns-server,192.168.38.12
dhcp-option= tag:CLUSTERNAME,option:domain-search,CLUSTERNAME.cars2.lab
dhcp-option= tag:CLUSTERNAME,option:ntp-server,192.168.38.12

# API (IPv4 + IPv6)
address=/api.CLUSTERNAME.cars2.lab/IPV4
address=/api.CLUSTERNAME.cars2.lab/IPV6
ptr-record=IPV4_REVERSE.in-addr.arpa,api.CLUSTERNAME.cars2.lab
ptr-record=IPV6_REVERSE.ip6.arpa,api.CLUSTERNAME.cars2.lab

# API internal (IPv4 + IPv6)
address=/api-int.CLUSTERNAME.cars2.lab/IPV4
address=/api-int.CLUSTERNAME.cars2.lab/IPV6

# Wildcard apps (IPv4 + IPv6)
address=/.apps.CLUSTERNAME.cars2.lab/IPV4
address=/.apps.CLUSTERNAME.cars2.lab/IPV6

# Node hostname
dhcp-host=NODE_MAC,IPV4,NODE_HOSTNAME, set:CLUSTERNAME
address=/NODE_HOSTNAME/IPV4
address=/NODE_HOSTNAME/IPV6
ptr-record=IPV4_REVERSE.in-addr.arpa,NODE_HOSTNAME
ptr-record=IPV6_REVERSE.ip6.arpa,NODE_HOSTNAME
```

**Generating the reverse IPv6 nibble string:**

The IPv6 PTR record requires the address expanded to full 32 hex digits, reversed character by character, and dot-separated. For example, `2600:52:7:300::145` expands to `2600:0052:0007:0300:0000:0000:0000:0145`, then reversed:

```bash
python3 -c "
import ipaddress, sys
addr = ipaddress.ip_address(sys.argv[1])
print('.'.join(reversed(addr.exploded.replace(':',''))))
" 2600:52:7:300::145
```

Output: `5.4.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.3.0.7.0.0.0.2.5.0.0.0.0.6.2`

**After editing, restart dnsmasq and verify:**

```bash
sudo systemctl restart dnsmasq
```

From the KVM host:

```bash
dig api.CLUSTERNAME.cars2.lab @192.168.38.12
dig console-openshift-console.apps.CLUSTERNAME.cars2.lab @192.168.38.12
```

### ClusterImageSet

The hub must have a ClusterImageSet for the target OCP version. Verify:

```bash
oc get clusterimagesets | grep 4.20
```

We are using `img4.20.14-x86-64-appsub` which maps to:
`quay.io/openshift-release-dev/ocp-release:4.20.14-x86_64`

## Git Repo Setup

The deployment config was originally sourced from:
https://github.com/novacain1/carslab-public/tree/main/rhocp-clusters/bronco.cars2.lab

The Bronco-specific files were extracted into a standalone repo:
https://github.com/apj72/bronco-sno

### Repo Structure

```
bronco-sno/
├── 00-hub-prereqs/
│   ├── agentserviceconfig.yaml    # Deploys the assisted-service
│   ├── bmh-secret.yaml            # BMC credentials (legacy, kept for reference)
│   ├── namespace.yaml             # bronco namespace (legacy, kept for reference)
│   ├── pull-secret.yaml           # Pull secret placeholder
│   └── kustomization.yaml
├── 01-hub-apps/
│   ├── cars2-clusters-bronco-app.yaml   # ArgoCD Application
│   └── kustomization.yaml
├── manifests/                     # Direct resource manifests (active)
│   ├── 01-namespace.yaml          # bronco namespace
│   ├── 02-clusterdeployment.yaml  # Hive ClusterDeployment
│   ├── 03-agentclusterinstall.yaml # Assisted install config
│   ├── 04-infraenv.yaml           # Discovery ISO / InfraEnv
│   ├── 05-nmstateconfig.yaml      # Static network config
│   ├── 06-baremetalhost.yaml      # BareMetalHost (iDRAC)
│   ├── 07-managedcluster.yaml     # ACM ManagedCluster + KlusterletAddonConfig
│   ├── 08-bmh-secret.yaml         # BMC credentials
│   └── kustomization.yaml
├── bronco-clusterinstance.yaml    # ClusterInstance (not used - siteconfig operator not available)
├── bronco-siteconfig.yaml         # Legacy SiteConfig (not used - requires ZTP plugin)
├── cis-4.16.yaml                  # Legacy ClusterImageSet (not used)
├── kustomization.yaml             # Top-level kustomization -> manifests/
└── install.md                     # This file
```

## Design Decisions

### Telco RDS Install-Time Settings

The `AgentClusterInstall` manifest (`manifests/03-agentclusterinstall.yaml`) includes two
install-time-only settings in `installConfigOverrides` that **cannot** be changed after
the cluster is deployed:

1. **`cpuPartitioningMode: AllNodes`** — Enables workload partitioning so that OpenShift
   management workloads (kubelet, CRI-O, etc.) are pinned to reserved CPUs. This is a
   prerequisite for the day-2 `PerformanceProfile` to isolate workload CPUs. Without it,
   the cluster is not telco RDS compliant.

2. **`baselineCapabilitySet: None`** with `additionalEnabledCapabilities: [marketplace, NodeTuning]`
   — Disables all optional cluster capabilities except OLM marketplace (needed to install
   operators) and NodeTuning (needed for PerformanceProfile/Tuned). This reduces the
   cluster footprint for edge/RAN deployments.

If you need to change either of these, you must **reinstall** the cluster. See
`Telco_RDS_spoke_install.md` for the full RDS compliance guide and teardown procedure.

### Why Not SiteConfig (ran.openshift.io/v1)?

The original novacain1 repo used the legacy `SiteConfig` CR which acts as a kustomize generator plugin. This requires the ZTP site-generate plugin to be installed in the ArgoCD repo-server, which was not configured on the m4 hub. Error: `external plugins disabled; unable to load external plugin 'SiteConfig'`

### Why Not ClusterInstance (siteconfig.open-cluster-management.io/v1alpha1)?

MCE 2.9.2 includes the `ClusterInstance` CRD but the SiteConfig operator that reconciles it was not deployed on the hub. No controller pods were found and the component could not be enabled through MCE configuration.

### Direct Resource Approach

The manifests in `manifests/` are the individual Kubernetes resources that both SiteConfig and ClusterInstance ultimately generate. They work directly with the assisted-service and Hive operators that are running on the hub. No plugins or additional operators required.

The resources are:

| Resource | API | Purpose |
|----------|-----|---------|
| Namespace | v1 | `bronco` namespace for all resources |
| ClusterDeployment | hive.openshift.io/v1 | Defines the cluster to Hive |
| AgentClusterInstall | extensions.hive.openshift.io/v1beta1 | Install configuration (networking, image, SSH key) |
| InfraEnv | agent-install.openshift.io/v1beta1 | Discovery ISO generation |
| NMStateConfig | agent-install.openshift.io/v1beta1 | Static network config for the node |
| BareMetalHost | metal3.io/v1alpha1 | Server BMC/iDRAC definition |
| ManagedCluster | cluster.open-cluster-management.io/v1 | ACM cluster registration |
| KlusterletAddonConfig | agent.open-cluster-management.io/v1 | ACM addon configuration |
| Secret | v1 | BMC credentials |

## Cluster Configuration Details

- **Cluster name:** bronco
- **Base domain:** cars2.lab (API will be at `api.bronco.cars2.lab`)
- **Network plugin:** OVNKubernetes
- **Capability trimming:** `baselineCapabilitySet: None`, only `marketplace` + `NodeTuning` enabled
- **Workload partitioning:** `cpuPartitioningMode: AllNodes` — enables management workload isolation at install time (required for telco RDS compliance)
- **Dual-stack networking:**
  - Cluster network: `10.128.0.0/14` (v4) + `fd01::/48` (v6)
  - Service network: `172.30.0.0/16` (v4) + `fd02::/112` (v6)
  - Machine network: `192.168.38.128/26` (v4) + `2600:52:7:300::0/64` (v6)
- **Node:** spr760-1.bronco.cars2.lab
  - BMC: iDRAC at `192.168.38.208` (Redfish virtual media)
  - Boot MAC: `ec:2a:72:51:31:b8` (interface eno8303)
  - Static IP: `192.168.38.145` / `2600:52:7:300::145`
  - Root disk: `/dev/disk/by-path/pci-0000:c7:00.0-scsi-0:2:15:0`
  - DNS: `192.168.38.12`, `2600:52:7:38::12`
  - NTP: `clock.cars2.lab`, `clock-v6.cars2.lab`
  - Default routes: `192.168.38.129` (v4), `2600:52:7:300::1` (v6)

## Installation Steps

### Step 1: Log in to the hub cluster

SSH to the jump box, switch to the working directory, and become root:

```bash
ssh -A ajoyce@192.168.38.31
cd /local_home/ajoyce
sudo su
```

The hub uses token-based authentication. Either use a saved service account token
(see below) or get a short-lived token from the web console at:
`https://oauth-openshift.apps.m4.cars2.lab/oauth/token/request`

```bash
oc login --token=<your-token> --server=https://api.m4.cars2.lab:6443
oc whoami   # should return kube:admin (or hub-admin SA)
```

#### Optional: Create a long-lived service account token

To avoid fetching a token from the web console every time, create a service account
with a long-lived token. Run this once while logged in to the hub:

```bash
oc create sa hub-admin -n openshift-gitops
oc adm policy add-cluster-role-to-user cluster-admin -z hub-admin -n openshift-gitops
oc create token hub-admin -n openshift-gitops --duration=8760h
```

Save the token on the jump box:

```bash
echo '<the-token>' > /local_home/ajoyce/hub-token
chmod 600 /local_home/ajoyce/hub-token
```

Then future logins become:

```bash
oc login --token=$(cat /local_home/ajoyce/hub-token) --server=https://api.m4.cars2.lab:6443
```

### Step 2: Clone the repo on the jump box

```bash
git clone https://github.com/apj72/bronco-sno.git /local_home/ajoyce/bronco-sno
cd /local_home/ajoyce/bronco-sno
```

### Step 3: Ensure assisted-service is running

```bash
oc get agentserviceconfig
oc get pods -n multicluster-engine | grep assisted
```

If the AgentServiceConfig doesn't exist, create it:

```bash
oc apply -f 00-hub-prereqs/agentserviceconfig.yaml
```

Wait for both `assisted-service` and `assisted-image-service` pods to be Running and Ready.

### Step 4: Check for existing bronco namespace

If re-deploying, ensure no stale namespace exists:

```bash
oc get project bronco 2>/dev/null && echo "EXISTS" || echo "NOT FOUND"
```

If it exists from a previous attempt, delete it and wait for cleanup:

```bash
oc delete project bronco
```

### Step 5: Create the pull secret

The pull secret is not included in the repo for security reasons. The namespace will be created by ArgoCD, but the pull secret needs to be created after the namespace exists.

Option A -- Apply manifests first, then create the pull secret:

```bash
cd /local_home/ajoyce/bronco-sno
oc apply -k manifests/
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/pull-secret.json
oc create secret generic assisted-deployment-pull-secret -n bronco --from-file=.dockerconfigjson=/tmp/pull-secret.json --type=kubernetes.io/dockerconfigjson
rm /tmp/pull-secret.json
```

Option B -- If using ArgoCD (step 6), create the namespace and pull secret first:

```bash
oc create namespace bronco
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/pull-secret.json
oc create secret generic assisted-deployment-pull-secret -n bronco --from-file=.dockerconfigjson=/tmp/pull-secret.json --type=kubernetes.io/dockerconfigjson
rm /tmp/pull-secret.json
```

### Step 6: Apply via ArgoCD (GitOps approach)

Apply the ArgoCD Application to trigger a GitOps-managed deployment:

```bash
cd /local_home/ajoyce/bronco-sno
oc apply -k 01-hub-apps/
```

Verify the ArgoCD application is syncing:

```bash
oc get applications.argoproj.io cars2-clusters-bronco -n openshift-gitops
```

Expected: `SYNC STATUS: Synced`, `HEALTH STATUS: Healthy` or `Progressing`

### Step 7: Monitor the installation

Watch the cluster deployment progress:

```bash
# Check the AgentClusterInstall status
oc get agentclusterinstall bronco -n bronco

# Watch for the BareMetalHost to be provisioned
oc get bmh -n bronco

# Watch for the InfraEnv ISO to be created
oc get infraenv bronco -n bronco

# Watch for the agent to register
oc get agents -n bronco

# Monitor overall cluster deployment
oc get managedcluster bronco

# Detailed install progress
oc get agentclusterinstall bronco -n bronco -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## Installation Flow Summary

1. ArgoCD syncs the Git repo and applies all resources in `manifests/`
2. Hive creates the ClusterDeployment
3. The assisted-service processes the AgentClusterInstall and InfraEnv, generating a discovery ISO
   - `cpuPartitioningMode: AllNodes` and capability trimming are baked into the install config
4. The BareMetalHost controller powers on the server via iDRAC/Redfish and boots from the ISO
5. The discovery agent on the server registers with the assisted-service
6. The assisted-service validates the host and begins installation
7. OCP 4.20.14 is installed as a single-node cluster with workload partitioning enabled
8. Once complete, the ManagedCluster is registered with ACM
9. Day-2 configuration is applied (manually or via hub policies) — see `Telco_RDS_spoke_install.md`

## Post-Install Access

Once the install completes (100%), retrieve the credentials:

```bash
# Get kubeconfig
oc get secret bronco-admin-kubeconfig -n bronco -o jsonpath='{.data.kubeconfig}' | base64 -d > ~/bronco-kubeconfig

# Get kubeadmin password
oc get secret bronco-admin-password -n bronco -o jsonpath='{.data.password}' | base64 -d && echo

# Test access
KUBECONFIG=~/bronco-kubeconfig oc get nodes
KUBECONFIG=~/bronco-kubeconfig oc get clusterversion
```

The console is available at: `https://console-openshift-console.apps.bronco.cars2.lab`
Login with username `kubeadmin` and the password from the command above.

### Verify Install-Time RDS Settings

After the cluster is accessible, confirm the two install-time settings were applied:

```bash
export KUBECONFIG=~/bronco-kubeconfig

# Workload partitioning — should print a JSON management annotation
oc get node -o jsonpath='{.items[0].metadata.annotations.node\.workload\.openshift\.io/management}' && echo

# Capability trimming — should show only marketplace and NodeTuning
oc get clusterversion version -o jsonpath='{.status.capabilities.enabledCapabilities}' | python3 -m json.tool
```

If workload partitioning is empty or capabilities show all defaults, the `installConfigOverrides`
in `manifests/03-agentclusterinstall.yaml` were not applied. The cluster must be torn down and
reinstalled — see `Telco_RDS_spoke_install.md` Appendix D for the teardown procedure.

### Accessing from a Local Mac (or other non-lab machine)

Machines outside the lab don't use the lab DNS server (`192.168.38.12`), so `*.cars2.lab` hostnames won't resolve. To fix this, create a macOS resolver file that forwards all `cars2.lab` lookups to the lab DNS:

```bash
sudo mkdir -p /etc/resolver
sudo bash -c 'echo "nameserver 192.168.38.12" > /etc/resolver/cars2.lab'
```

This tells macOS to send any `*.cars2.lab` DNS query to `192.168.38.12`. It applies to all clusters in the lab (m4, bronco, etc.) with no further changes. Your Mac must have network connectivity to `192.168.38.12` (e.g. via VPN).

Verify it works:

```bash
dig console-openshift-console.apps.bronco.cars2.lab
ping -c 1 api.bronco.cars2.lab
```

You can then copy the kubeconfig to your Mac and use it locally:

```bash
scp ajoyce@192.168.38.31:/tmp/bronco-kubeconfig ~/.kube/bronco-kubeconfig
KUBECONFIG=~/.kube/bronco-kubeconfig oc get nodes
```

## Troubleshooting

### ArgoCD sync errors

Check the application status:

```bash
oc get applications.argoproj.io cars2-clusters-bronco -n openshift-gitops -o yaml | tail -30
```

Common issues:
- **RBAC forbidden** -- Grant cluster-admin to the ArgoCD SA (see prerequisites)
- **"external plugins disabled"** -- You're using the legacy SiteConfig format, switch to direct manifests
- **"project X does not exist"** -- Update the ArgoCD Application to use `default` project

### Assisted-service pods stuck in Pending/Evicted

Check for scheduling issues:

```bash
oc describe pod <pod-name> -n multicluster-engine | tail -20
```

Common causes:
- **Memory pressure** -- Disable unnecessary MCE components (hypershift, discovery)
- **Disk pressure** -- Clean up audit logs and old images (see prerequisites)
- **Volume affinity conflict** -- LSO PVs are node-specific; check which node has the PVs

### BareMetalHost not provisioning

```bash
oc get bmh -n bronco -o yaml | grep -A 10 "status:"
```

Check BMC connectivity from the hub and verify iDRAC credentials.

### Agent not registering

```bash
oc get infraenv bronco -n bronco -o jsonpath='{.status}'
oc get agents -n bronco
```

Verify the server has booted from the discovery ISO and can reach the hub network.
