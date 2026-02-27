# Telco RAN DU RDS Compliant SNO Spoke Install — Bronco

This document describes how to install the Bronco Single Node OpenShift (SNO) cluster as a **Red Hat Telco RAN DU Reference Design Specification (RDS) compliant** spoke cluster, deployed from the m4 ACM hub.

## Reference Documentation

| Document | URL |
|----------|-----|
| Telco RAN DU RDS (OCP 4.20) | https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/scalability_and_performance/telco-ran-du-ref-design-specs |
| Telco Core RDS (OCP 4.20) | https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/scalability_and_performance/telco-core-ref-design-specs |
| Telco Reference CRs (4.20, GitHub) | https://github.com/openshift-kni/telco-reference/tree/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs |
| Telco Reference Extra Manifests | https://github.com/openshift-kni/telco-reference/tree/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/extra-manifest |
| Workload Partitioning Docs (OCP 4.20) | https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/scalability_and_performance/workload-partitioning |
| 5G RAN RDS Lab (manual walkthrough) | https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/welcome.html |
| Lab SNO Config Files (GitHub) | https://github.com/RHsyseng/5g-ran-deployments-on-ocp-lab/tree/lab-4.20/lab-materials/sno-config |

## Environment Overview

| Component | Detail |
|-----------|--------|
| Hub cluster | m4.cars2.lab (OCP 4.18.15, 3-node compact) |
| Hub API | api.m4.cars2.lab:6443 |
| Jump box (KVM host) | 192.168.38.31 (`ssh -A ajoyce@192.168.38.31`) |
| SNO target | Bronco (Dell R760, hostname: spr760-1.bronco.cars2.lab) |
| Bronco iDRAC | 192.168.38.208 |
| OCP version | 4.20.14 |
| Git repo | https://github.com/apj72/bronco-sno |
| Repo clone on jump box | `/local_home/ajoyce/bronco-sno` |

## What Makes a Cluster RDS Compliant?

The telco RAN DU RDS defines a validated, supported configuration split into two phases:

### Phase 1: Install-Time Configuration

These settings **must** be applied during initial cluster installation. They cannot be changed after the fact.

| Requirement | Status | Notes |
|-------------|--------|-------|
| `cpuPartitioningMode: AllNodes` | **REQUIRED** — set via `agent-install.openshift.io/install-config-overrides` annotation | Enables workload partitioning at install time |
| Capability trimming (`baselineCapabilitySet: None`) | **REQUIRED** — set via same annotation | Only `NodeTuning` + `OperatorLifecycleManager` + `Ingress` enabled |
| OVNKubernetes network plugin | Already configured | Required for telco RDS |
| UEFI boot mode | Already configured | Set in BareMetalHost |
| Static networking (NMState) | Already configured | Dual-stack IPv4+IPv6 |

### Phase 2: Day-2 Configuration (Post-Install)

These are applied to the running cluster via ACM policies after installation completes. They are matched to the spoke cluster via labels on the `ManagedCluster` CR.

| Component | Purpose | RDS Requirement |
|-----------|---------|-----------------|
| **PerformanceProfile** | CPU isolation, hugepages, RT kernel, NUMA topology | Required |
| **PTP Operator + PtpConfig** | Precision time synchronization for RAN | Required |
| **SR-IOV Operator + SriovNetworkNodePolicy** | High-throughput/low-latency secondary networks | Required |
| **SCTP MachineConfig** | Enable SCTP protocol (disabled by default in RHCOS) | Required |
| **Container runtime (crun)** | Set container runtime to `crun` | Required |
| **Kubelet tuning + container mount hiding** | Reduce housekeeping CPU, hide mount points | Required |
| **CRI-O wipe disable** | Prevent image cache wipe on unclean shutdown | Required |
| **Cluster monitoring config** | Reduce Prometheus retention to 24h, disable alertmanager/telemeter | Required |
| **Console Operator disable** | Reduce resource usage | Required |
| **Networking diagnostics disable** | Not needed on SNO | Required |
| **Single OperatorHub catalog source** | Reduce CPU from catalog polling | Required |
| **SR-IOV kernel arguments** | IOMMU enablement via MachineConfig | Required |
| **RCU Normal systemd service** | Set `rcu_normal` after boot | Required |
| **One-shot time sync** | NTP sync at boot | Required |
| **kdump** | Optional (enabled by default), captures kernel panic debug info | Optional |
| **Local Storage Operator or LVM Storage** | Persistent storage for workloads | Required (one of) |
| **Logging (Vector)** | Log forwarding from edge node | Required |
| **Lifecycle Agent** | Image-based upgrades for SNO | Optional |
| **SRIOV-FEC Operator** | FEC accelerator support | Optional |

## Hardware Profile (queried from iDRAC)

| Component | Detail |
|-----------|--------|
| Server | Dell PowerEdge R760 |
| CPU | Intel Xeon Gold 6421N — 1 socket, 32 cores, 64 threads (HT), 4.0 GHz max |
| Memory | 128 GB |
| NUMA | Single NUMA node (1 socket) |
| NIC: Embedded (Broadcom 1GbE) | eno8303 `EC:2A:72:51:31:B8` (boot), eno8403 `EC:2A:72:51:31:B9` |
| NIC: Integrated OCP (Intel E810-XXV 4P 25GbE) | eno12399 `40:A6:B7:A8:79:C8`, eno12409 `...C9`, eno12419 `...CA`, eno12429 `...CB` |
| NIC: Slot 2 (Intel E810-XXVDA4T 4P 25GbE) | ens2f0 `50:7C:6F:1F:B3:98`, ens2f1 `...99`, ens2f2 `...9A`, ens2f3 `...9B` |

Both E810 NICs are SR-IOV and PTP capable.

## CPU Partitioning Plan

With 1 socket / 32 cores / 64 threads, HT sibling of CPU N is CPU N+32. To comply with the
RDS requirement that HT siblings are not split across reserved/isolated sets:

| Parameter | Value | Notes |
|-----------|-------|-------|
| Reserved CPUs | `0-3,32-35` | 4 physical cores (8 HTs). Includes core 0 of the single NUMA node. |
| Isolated CPUs | `4-31,36-63` | 28 physical cores (56 HTs). Available for workload pods. |
| Hugepages (1G) | 4 | Minimal for a learning environment; increase for real CNF workloads. |

> **Note:** The HT sibling mapping (N ↔ N+32) should be verified after OS boot with
> `cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list`.

The RDS requires:
- At least 4 hyperthreads (2 physical cores) reserved
- Core 0 of **each NUMA node** must be in the reserved set
- HT siblings must not be split across reserved/isolated sets
- Platform CPU budget: less than 4000mc (2 cores / 4 HTs) at steady state

## Design Decisions (Learning Environment)

This is a learning/reference environment, not a production CNF deployment. The following
sensible defaults are used:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| RT kernel | Enabled | Bare metal supports it; learn the real RDS config |
| Hugepages | 4 x 1G | Minimal; same as the 5G RAN lab |
| PTP role | Ordinary clock (T-TSC) | Simplest config; no GPS/grandmaster required |
| PTP NIC | eno12399 (E810 integrated) | First available E810 port |
| SR-IOV | 2 VFs on eno12399 as `netdevice` | Proves SR-IOV works without needing DPDK workloads |
| Storage | LVM Storage | Dynamic provisioning, simpler than LSO for learning |
| Logging | Deploy operator only | No log forwarding target configured |

---

## Step-by-Step Installation

### Step 0: Check for Existing ACM Policies on the Hub

Before installing, verify what day-2 policies exist on the hub that will bind to this cluster. The bronco `ManagedCluster` has labels `common-du-416: "true"` and `group-dellr760-vse4: ""`.

SSH to the jump box and log in to the hub:

```bash
ssh -A ajoyce@192.168.38.31
cd /local_home/ajoyce
sudo su
```

The hub uses token-based authentication. Get a token from:
`https://oauth-openshift.apps.m4.cars2.lab/oauth/token/request`

```bash
oc login --token=<your-token> --server=https://api.m4.cars2.lab:6443
```

Check for policies that match these labels:

```bash
# List all policies
oc get policies -A | head -20

# Check for policies targeting common-du-416 label
oc get placementrules -A -o yaml | grep -A5 "common-du-416" 2>/dev/null
oc get placementbindings -A

# Check for PolicyGenTemplate or PolicyGenerator CRs
oc get policygentemplate -A 2>/dev/null
oc get configurationpolicy -A 2>/dev/null | head -20

# Check what policies are bound to the bronco cluster (if it already exists as a ManagedCluster)
oc get policies -A -l cluster-name=bronco 2>/dev/null
```

**What to look for:**
- Policies that deploy PerformanceProfile, PTP, SR-IOV, SCTP MachineConfig, monitoring config, etc.
- If these policies exist and match the bronco labels, day-2 configuration will be applied automatically after install.
- If they do not exist, you will need to create them manually or via GitOps after the cluster is deployed.

> **Action:** Document findings here after running the commands above.
> If policies exist that deploy the same resources we configure manually below
> (e.g., PerformanceProfile, SR-IOV, PTP), either remove the policies or skip
> the corresponding manual steps to avoid conflicts.

### Step 1: Update Install-Time Manifests for RDS Compliance

The critical missing piece is `cpuPartitioningMode: AllNodes` in the `installConfigOverrides`. This **must** be set before the cluster is deployed.

#### 1a. Update `manifests/03-agentclusterinstall.yaml`

Add the `agent-install.openshift.io/install-config-overrides` **annotation** to enable
`cpuPartitioningMode` and capability trimming.

> **Important:** The `installConfigOverrides` **spec field** does not exist in the
> AgentClusterInstall CRD on MCE 2.9.x. Kubernetes silently accepts unknown spec fields
> but the assisted-service controller ignores them. You **must** use the annotation.

```yaml
metadata:
  name: bronco
  namespace: bronco
  annotations:
    agent-install.openshift.io/install-config-overrides: '{"cpuPartitioningMode":"AllNodes","capabilities":{"baselineCapabilitySet":"None","additionalEnabledCapabilities":["NodeTuning","OperatorLifecycleManager","Ingress"]}}'
```

> **Note:** These three capabilities are the minimum required by the telco RDS reference
> for OCP 4.20 SNO. `Ingress` is mandatory (installer rejects without it),
> `OperatorLifecycleManager` is needed to install day-2 operators, and `NodeTuning`
> is needed for PerformanceProfile/Tuned. `marketplace` is not required — OLM can
> install operators without it.

#### 1b. Verify the ManagedCluster labels

The `ManagedCluster` labels in `manifests/07-managedcluster.yaml` determine which ACM policies bind to this cluster. Ensure the labels match the policies on the hub:

```yaml
labels:
  cloud: BareMetal
  vendor: OpenShift
  common-du-416: "true"
  group-dellr760-vse4: ""
```

> **Note:** If the hub policies use different label selectors, update these labels accordingly.

#### 1c. (Optional) Disable non-essential KlusterletAddonConfig components

The RDS recommends disabling all RHACM add-ons except `policy-controller` and `observability-controller`. Update `manifests/07-managedcluster.yaml`:

```yaml
spec:
  clusterName: bronco
  clusterNamespace: bronco
  clusterLabels:
    cloud: BareMetal
    vendor: OpenShift
  applicationManager:
    enabled: false
  certPolicyController:
    enabled: false
  iamPolicyController:
    enabled: false
  policyController:
    enabled: true
  searchCollector:
    enabled: false
```

### Step 2: Commit and Push Changes

After making the manifest changes:

```bash
cd /local_home/ajoyce/bronco-sno
git add -A
git commit -m "Enable cpuPartitioningMode for telco RDS compliance"
git push origin main
```

### Step 3: Hub Prerequisites

Verify all hub prerequisites from the jump box:

```bash
ssh -A ajoyce@192.168.38.31
oc login https://api.m4.cars2.lab:6443
```

```bash
# Assisted-service running
oc get pods -n multicluster-engine | grep assisted

# RHCOS 4.20 image available
oc get agentserviceconfig agent -o jsonpath='{.spec.osImages}' | python3 -m json.tool

# Bare metal operator watching all namespaces
oc get provisioning -o jsonpath='{.items[0].spec.watchAllNamespaces}'

# ClusterImageSet exists
oc get clusterimagesets | grep 4.20

# ArgoCD SA has cluster-admin
oc get clusterrolebinding | grep openshift-gitops-argocd-application-controller
```

### Step 4: Clean State Check

Ensure no stale resources from a previous attempt:

```bash
oc get project bronco 2>/dev/null && echo "EXISTS - delete first" || echo "CLEAN"
```

If it exists:

```bash
oc delete project bronco
# Wait for namespace termination
watch oc get project bronco
```

### Step 5: Create Pull Secret

The pull secret must exist in the `bronco` namespace before the assisted-service can generate the discovery ISO.

```bash
oc create namespace bronco

oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/pull-secret.json

oc create secret generic assisted-deployment-pull-secret -n bronco \
  --from-file=.dockerconfigjson=/tmp/pull-secret.json \
  --type=kubernetes.io/dockerconfigjson

rm /tmp/pull-secret.json
```

### Step 6: Deploy via ArgoCD

Apply the ArgoCD application to trigger GitOps-managed deployment:

```bash
cd /local_home/ajoyce/bronco-sno
git pull  # ensure latest changes
oc apply -k 01-hub-apps/
```

Verify the ArgoCD app is syncing:

```bash
oc get applications.argoproj.io cars2-clusters-bronco -n openshift-gitops
```

Expected: `SYNC STATUS: Synced`, `HEALTH STATUS: Healthy` or `Progressing`

### Step 7: Monitor Installation

```bash
# Watch all key resources
watch -n 10 'echo "=== AgentClusterInstall ===" && oc get agentclusterinstall bronco -n bronco && echo && echo "=== BareMetalHost ===" && oc get bmh -n bronco && echo && echo "=== Agents ===" && oc get agents -n bronco && echo && echo "=== ManagedCluster ===" && oc get managedcluster bronco'
```

Detailed progress:

```bash
# Install conditions
oc get agentclusterinstall bronco -n bronco -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Check if workload partitioning was enabled
oc get agentclusterinstall bronco -n bronco -o jsonpath='{.spec.installConfigOverrides}' | python3 -m json.tool
```

### Step 8: Post-Install Verification

Once installation completes (100%):

```bash
# Get kubeconfig
oc get secret bronco-admin-kubeconfig -n bronco -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/bronco-kubeconfig

# Get kubeadmin password
oc get secret bronco-admin-password -n bronco -o jsonpath='{.data.password}' | base64 -d && echo

# Test access
KUBECONFIG=/tmp/bronco-kubeconfig oc get nodes
KUBECONFIG=/tmp/bronco-kubeconfig oc get clusterversion
```

#### Verify RDS Install-Time Settings

```bash
export KUBECONFIG=/tmp/bronco-kubeconfig

# Verify workload partitioning is enabled
oc get node -o jsonpath='{.items[0].metadata.annotations}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('Workload Partitioning:', d.get('node.workload.openshift.io/management', 'NOT SET'))"

# Verify capability trimming
oc get clusterversion version -o jsonpath='{.status.capabilities}'

# Verify network type
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.type}'
```

---

## Day-2: RDS Configuration on the Spoke

> **Lab reference:** This section follows the same approach as the
> "Configure Seed Cluster" section of the
> [5G RAN RDS Lab](https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/lab-environment.html).
> The lab uses VMs on a disconnected KVM environment; the steps below are
> adapted for the bronco bare-metal Dell R760 on the connected cars2.lab.
>
> Lab config files:
> https://github.com/RHsyseng/5g-ran-deployments-on-ocp-lab/tree/lab-4.20/lab-materials/sno-config

### How Day-2 Config Works in Production vs Manual Learning

In production telco deployments, all day-2 configuration (Steps 9-17) is
**automated via ACM policies stored in Git**. The standard flow is:

1. **PolicyGenerator CRs** in a Git repo define the desired configuration
   (PerformanceProfile, SR-IOV, PTP, operator subscriptions, MachineConfigs, etc.)
2. **ArgoCD** on the hub syncs these PolicyGenerator CRs and renders them into
   `Policy`, `PlacementBinding`, and `PlacementRule` resources
3. **ACM** matches policies to clusters via **ManagedCluster labels**
   (e.g., `common-du-416: "true"`, `group-dellr760-vse4: ""`)
4. When a spoke cluster joins and has matching labels, ACM automatically
   pushes all the configuration — no manual intervention required

This is the approach used by **ZTP (Zero Touch Provisioning)** and is
documented in the [5G RAN RDS Lab — ZTP section](https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/ztp-at-scale.html).

The Red Hat telco-reference repo has the actual source CRs:
https://github.com/openshift-kni/telco-reference/tree/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs

**If ACM policies are configured on the hub** that match bronco's labels,
the day-2 config will be applied automatically after the cluster joins.
Check Step 0 to see if those policies exist. If they do, skip to
**Step 18: Final RDS Verification**.

**If ACM policies are not configured** (or you want to understand each
component), follow the manual steps below. These apply the same
configuration that ACM policies would, just one step at a time.

---

### Manual Day-2 Steps

All day-2 commands below run **on the bronco spoke cluster** from the jump box:

```bash
ssh -A ajoyce@192.168.38.31
cd /local_home/ajoyce
sudo su

# Log in to the hub (get token from https://oauth-openshift.apps.m4.cars2.lab/oauth/token/request)
oc login --token=<your-token> --server=https://api.m4.cars2.lab:6443

# Get bronco kubeconfig from the hub
oc get secret bronco-admin-kubeconfig -n bronco -o jsonpath='{.data.kubeconfig}' | base64 -d > ~/bronco-kubeconfig

# Switch to bronco spoke
export KUBECONFIG=~/bronco-kubeconfig
oc get nodes
oc get clusterversion
```

### Step 9: Reduce Monitoring Footprint

> **Lab reference:** Not a separate step in the lab, but required by the RDS.
> See [ReduceMonitoringFootprint.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/ReduceMonitoringFootprint.yaml)

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    alertmanagerMain:
      enabled: false
    telemeterClient:
      enabled: false
    prometheusK8s:
      retention: 24h
EOF
```

### Step 10: Disable Console Operator

> **Lab reference:** Not a separate step in the lab, but required by the RDS.
> See [ConsoleOperatorDisable.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/ConsoleOperatorDisable.yaml)

```bash
oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: Console
metadata:
  name: cluster
spec:
  logLevel: Normal
  managementState: Removed
  operatorLogLevel: Normal
EOF
```

### Step 11: Disable SNO Network Diagnostics

> **Lab reference:** Not a separate step in the lab, but required by the RDS.
> See [DisableSnoNetworkDiag.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/DisableSnoNetworkDiag.yaml)

```bash
oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  disableNetworkDiagnostics: true
EOF
```

### Step 11b: Create CatalogSource for OLM

> **Important:** Because we trimmed the `marketplace` capability, the
> `openshift-marketplace` namespace and default CatalogSources are not created
> automatically. We must create them manually before installing any operators.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators
  image: registry.redhat.io/redhat/redhat-operator-index:v4.20
  publisher: Red Hat
  sourceType: grpc
  grpcPodConfig:
    securityContextConfig: restricted
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
```

Wait for the catalog pod to be ready:

```bash
oc get pods -n openshift-marketplace -w
```

Once the pod shows `1/1 Running`, press `Ctrl+C` and proceed.

### Step 12: Deploy Day-2 Operators

> **Lab reference:** This is the equivalent of the lab's `02_*_deployment.yaml` files.
> See [Configure Seed Cluster](https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/lab-environment.html)
> section where it applies `02_sriov_deployment.yaml`, `02_ptp_deployment.yaml`,
> `02_logging_deployment.yaml`, `02_lvms_deployment.yaml`.
>
> **Key difference:** The lab uses `source: redhat-operator-index` (disconnected registry).
> Bronco uses `source: redhat-operators` (connected to Red Hat CDN).

#### 12a. SR-IOV Operator

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sriov-network-operator
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    workload.openshift.io/allowed: management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
    - openshift-sriov-network-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator-subscription
  namespace: openshift-sriov-network-operator
spec:
  channel: "stable"
  name: sriov-network-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

#### 12b. PTP Operator

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-ptp
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    workload.openshift.io/allowed: management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ptp-operators
  namespace: openshift-ptp
spec:
  targetNamespaces:
    - openshift-ptp
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ptp-operator-subscription
  namespace: openshift-ptp
spec:
  channel: "stable"
  name: ptp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

#### 12c. Cluster Logging Operator

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    workload.openshift.io/allowed: management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
    - openshift-logging
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: "stable-6.4"
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

#### 12d. LVM Storage Operator

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    workload.openshift.io/allowed: management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: lvms-operator-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
    - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: "stable-4.20"
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

#### 12e. Wait for all operators to install

```bash
echo "Waiting for SR-IOV operator..."
oc -n openshift-sriov-network-operator wait clusterserviceversion \
  -l operators.coreos.com/sriov-network-operator.openshift-sriov-network-operator \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s

echo "Waiting for PTP operator..."
oc -n openshift-ptp wait clusterserviceversion \
  -l operators.coreos.com/ptp-operator.openshift-ptp \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s

echo "Waiting for Logging operator..."
oc -n openshift-logging wait clusterserviceversion \
  -l operators.coreos.com/cluster-logging.openshift-logging \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s

echo "Waiting for LVM Storage operator..."
oc -n openshift-storage wait clusterserviceversion \
  -l operators.coreos.com/lvms-operator.openshift-storage \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s

echo "All operators installed."
```

### Step 13: Configure SR-IOV Operator

> **Lab reference:** Equivalent to the lab's `03_sriovoperatorconfig.yaml`.
> See [Configure Seed Cluster](https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/lab-environment.html).
> Also see [SriovOperatorConfigForSNO.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/SriovOperatorConfigForSNO.yaml)
>
> **Note:** The `SriovOperatorConfig` CR must be explicitly created for 4.20 — it is not auto-generated.
> `disableDrain: true` is required for SNO. Injector and webhook are disabled to reduce footprint.

```bash
oc apply -f - <<'EOF'
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovOperatorConfig
metadata:
  name: default
  namespace: openshift-sriov-network-operator
spec:
  configDaemonNodeSelector:
    node-role.kubernetes.io/master: ""
  disableDrain: true
  enableInjector: false
  enableOperatorWebhook: false
  logLevel: 0
EOF
```

#### 13b. SR-IOV Network Node Policy

> **Lab reference:** Equivalent to the lab's `03_sriov-nw-du-netdev.yaml`.
> Creates 2 VFs on the integrated E810 NIC (eno12399) as `netdevice` type.
> This is sufficient for a learning environment. For production, adjust the
> number of VFs and add `vfio-pci` policies as needed for DPDK workloads.
>
> **Note:** The PCI address of eno12399 must be confirmed after install.
> Run `oc debug node/<node> -- chroot /host ethtool -i eno12399` to get the bus-info.
> Substitute the PCI address below once known.

```bash
oc apply -f - <<'EOF'
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: bronco-e810-netdev
  namespace: openshift-sriov-network-operator
spec:
  deviceType: netdevice
  nicSelector:
    pfNames:
      - eno12399
  nodeSelector:
    node-role.kubernetes.io/master: ""
  numVfs: 2
  priority: 10
  resourceName: bronco_e810_netdev
EOF
```

#### 13c. SR-IOV Network (optional — creates a NetworkAttachmentDefinition)

```bash
oc apply -f - <<'EOF'
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: bronco-sriov-net
  namespace: openshift-sriov-network-operator
spec:
  ipam: '{"type":"host-local","subnet":"192.168.100.0/24"}'
  networkNamespace: default
  resourceName: bronco_e810_netdev
  vlan: 0
EOF
```

### Step 14: Configure PTP Operator

> **Lab reference:** Equivalent to the lab's `03_ptpoperatorconfig.yaml`.
> See [Configure Seed Cluster](https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/lab-environment.html).
> Also see [PtpOperatorConfig.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/PtpOperatorConfig.yaml)

```bash
oc apply -f - <<'EOF'
apiVersion: ptp.openshift.io/v1
kind: PtpOperatorConfig
metadata:
  name: default
  namespace: openshift-ptp
spec:
  daemonNodeSelector:
    node-role.kubernetes.io/master: ""
EOF
```

#### 14b. PTP Config (Ordinary Clock / T-TSC)

> **Lab reference:** See the telco-reference repo `PtpConfigSlave.yaml`.
> Configured as an ordinary clock (T-TSC) syncing from an upstream PTP source.
> Uses the integrated E810 NIC (eno12399) which supports hardware timestamping.
>
> **Note:** Without an upstream PTP grandmaster on the network, ptp4l will log
> errors about not receiving Announce messages. This is expected in a learning
> environment — the operator and daemon will still run correctly. If you have
> a PTP grandmaster available, this config will lock to it automatically.

```bash
oc apply -f - <<'EOF'
apiVersion: ptp.openshift.io/v1
kind: PtpConfig
metadata:
  name: bronco-ordinary-clock
  namespace: openshift-ptp
spec:
  profile:
    - name: ordinary-clock
      interface: eno12399
      ptp4lOpts: "-2 -s"
      phc2sysOpts: "-a -r -n 24"
  recommend:
    - profile: ordinary-clock
      priority: 10
      match:
        - nodeLabel: node-role.kubernetes.io/master
EOF
```

### Step 15: Apply PerformanceProfile

> **Lab reference:** Equivalent to the lab's `04_performance_profile.yaml`.
> See [Configure Seed Cluster](https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/lab-environment.html).
> Also see [PerformanceProfile.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/PerformanceProfile.yaml)
>
> **Key differences from the lab:**
> - Lab uses `isolated: 4-11` / `reserved: 0-3` (12 vCPUs on KVM)
> - Bronco: `reserved: 0-3,32-35` / `isolated: 4-31,36-63` (64 HTs on bare metal)
> - Lab disables RT kernel (`realTimeKernel.enabled: false`) because VMs don't support it
> - Bronco bare metal enables RT kernel for full RDS compliance
> - Hugepages: 4 x 1G (learning environment; increase for production CNFs)
>
> **This will trigger a node reboot.**

```bash
oc apply -f - <<'EOF'
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: openshift-node-performance-profile
  annotations:
    kubeletconfig.experimental: |
      {"topologyManagerScope": "pod",
       "systemReserved": {"memory": "3Gi"}
      }
    ran.openshift.io/reference-configuration: ran-du.redhat.com
spec:
  additionalKernelArgs:
    - rcupdate.rcu_normal_after_boot=0
    - efi=runtime
    - vfio_pci.enable_sriov=1
    - vfio_pci.disable_idle_d3=1
    - module_blacklist=irdma
  cpu:
    isolated: "4-31,36-63"
    reserved: "0-3,32-35"
  globallyDisableIrqLoadBalancing: false
  hugepages:
    defaultHugepagesSize: 1G
    pages:
      - count: 4
        size: 1G
  machineConfigPoolSelector:
    pools.operator.machineconfiguration.openshift.io/master: ""
  nodeSelector:
    node-role.kubernetes.io/master: ""
  numa:
    topologyPolicy: restricted
  realTimeKernel:
    enabled: true
  workloadHints:
    highPowerConsumption: false
    perPodPowerManagement: false
    realTime: true
EOF
```

Wait for the node to reboot and the PerformanceProfile to become available:

```bash
# This may take 10-15 minutes as the node reboots with the RT kernel
oc wait --for='jsonpath={.status.conditions[?(@.type=="Available")].status}=True' \
  performanceprofile openshift-node-performance-profile --timeout=1200s
```

### Step 16: Apply TunedPerformancePatch

> **Lab reference:** Equivalent to the lab's `05_TunedPerformancePatch.yaml`.
> See [Configure Seed Cluster](https://labs.sysdeseng.com/5g-ran-deployments-on-ocp-lab/4.20/lab-environment.html).
> Also see [TunedPerformancePatch.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/TunedPerformancePatch.yaml)

```bash
oc apply -f - <<'EOF'
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: performance-patch
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
    - name: performance-patch
      data: |
        [main]
        summary=Configuration changes profile inherited from performance created tuned
        include=openshift-node-performance-openshift-node-performance-profile
        [scheduler]
        group.ice-ptp=0:f:10:*:ice-ptp.*
        group.ice-gnss=0:f:10:*:ice-gnss.*
        group.ice-dplls=0:f:10:*:ice-dplls.*
        [service]
        service.stalld=start,enable
        service.chronyd=stop,disable
  recommend:
    - machineConfigLabels:
        machineconfiguration.openshift.io/role: master
      priority: 19
      profile: performance-patch
EOF
```

### Step 17: Apply SCTP MachineConfig

> **Lab reference:** Applied as an extra manifest at install time in the lab.
> For the manual approach, apply it as a day-2 MachineConfig.
> See [03-sctp-machine-config-master.yaml](https://github.com/openshift-kni/telco-reference/blob/konflux-telco-core-rds-4-20/telco-ran/configuration/source-crs/extra-manifest/03-sctp-machine-config-master.yaml)
>
> **This will trigger a node reboot.**

```bash
oc apply -f - <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: load-sctp-module-master
spec:
  config:
    ignition:
      version: 2.2.0
    storage:
      files:
        - contents:
            source: data:,
            verification: {}
          filesystem: root
          mode: 420
          path: /etc/modprobe.d/sctp-blacklist.conf
        - contents:
            source: data:text/plain;charset=utf-8,sctp
          filesystem: root
          mode: 420
          path: /etc/modules-load.d/sctp-load.conf
EOF
```

### Step 18: Final RDS Verification

After all day-2 configuration has been applied and the node has stabilised:

```bash
export KUBECONFIG=/tmp/bronco-kubeconfig

echo "=== Node Status ==="
oc get nodes

echo "=== Workload Partitioning ==="
oc get node -o jsonpath='{.items[0].metadata.annotations.node\.workload\.openshift\.io/management}' && echo

echo "=== Cluster Version & Capabilities ==="
oc get clusterversion version -o jsonpath='{.status.capabilities}' | python3 -m json.tool

echo "=== PerformanceProfile ==="
oc get performanceprofile

echo "=== Tuned ==="
oc get tuned -n openshift-cluster-node-tuning-operator

echo "=== SR-IOV Operator ==="
oc get csv -n openshift-sriov-network-operator
oc get sriovoperatorconfig -n openshift-sriov-network-operator

echo "=== PTP Operator ==="
oc get csv -n openshift-ptp
oc get ptpoperatorconfig -n openshift-ptp

echo "=== Logging Operator ==="
oc get csv -n openshift-logging

echo "=== LVM Storage ==="
oc get csv -n openshift-storage

echo "=== Monitoring Config ==="
oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' && echo

echo "=== Console Operator ==="
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' && echo

echo "=== Network Diagnostics ==="
oc get network.operator cluster -o jsonpath='{.spec.disableNetworkDiagnostics}' && echo

echo "=== SCTP Module ==="
oc get machineconfig | grep sctp

echo "=== Network Type ==="
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.type}' && echo
```

---

## RDS Compliance Checklist

Use this checklist to track compliance status after the cluster is fully deployed and day-2 config applied.

### Install-Time (Phase 1)

- [ ] `cpuPartitioningMode: AllNodes` set in installConfigOverrides
- [ ] `baselineCapabilitySet: None` with only `NodeTuning` + `OperatorLifecycleManager` + `Ingress`
- [ ] OVNKubernetes network plugin
- [ ] UEFI boot mode
- [ ] Static networking via NMState (dual-stack)
- [ ] Workload partitioning annotation present on node

### Day-2 — Cluster Tuning (Phase 2a)

- [ ] Cluster monitoring reduced (24h retention, alertmanager/telemeter disabled)
- [ ] Console Operator disabled (`managementState: Removed`)
- [ ] SNO networking diagnostics disabled
- [ ] SCTP enabled via MachineConfig

### Day-2 — Operators (Phase 2b)

- [ ] SR-IOV Operator installed and CSV `Succeeded`
- [ ] SriovOperatorConfig applied (disableDrain, no injector/webhook)
- [ ] SriovNetworkNodePolicy applied (2 VFs on eno12399 as `netdevice`)
- [ ] PTP Operator installed and CSV `Succeeded`
- [ ] PtpOperatorConfig applied
- [ ] PtpConfig applied (ordinary clock on eno12399)
- [ ] Cluster Logging Operator installed and CSV `Succeeded`
- [ ] LVM Storage Operator installed and CSV `Succeeded`

### Day-2 — Performance (Phase 2c)

- [ ] PerformanceProfile applied (reserved `0-3,32-35`, isolated `4-31,36-63`, 4x1G hugepages, RT kernel)
- [ ] PerformanceProfile status `Available=True`
- [ ] TunedPerformancePatch applied

### Post-Install Verification

- [ ] Verify HT sibling mapping matches expectations (`cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list`)
- [ ] Check ACM policies on hub (Step 0) and document findings
- [ ] Build automated ACM policy approach after validating manual config

---

## Appendix A: Install Flow Diagram

```
Hub (m4.cars2.lab)                           Spoke (bronco)
─────────────────                           ──────────────
1. ArgoCD syncs git repo
2. Creates manifests in bronco namespace
   ├─ Namespace
   ├─ ClusterDeployment
   ├─ AgentClusterInstall ───────────────── cpuPartitioningMode: AllNodes
   ├─ InfraEnv ──────────────────────────── Generates discovery ISO
   ├─ NMStateConfig
   ├─ BareMetalHost ─────────────────────── Powers on via iDRAC/Redfish
   ├─ ManagedCluster (labels for policies)
   └─ BMC Secret
3. Assisted-service generates ISO
4. BMH controller boots server from ISO ──► Server boots discovery ISO
                                           5. Discovery agent registers
6. Assisted-service validates host
7. Assisted-service begins install ───────► OCP 4.20.14 installed as SNO
                                              with workload partitioning
8. Install completes
9. ManagedCluster registered with ACM

MANUAL DAY-2 (on the spoke):
 9. Reduce monitoring footprint
10. Disable Console Operator
11. Disable network diagnostics
12. Deploy operators (SR-IOV, PTP, Logging, LVM Storage)
13. Configure SR-IOV:
    a. SriovOperatorConfig (disableDrain, no injector/webhook)
    b. SriovNetworkNodePolicy (2 VFs on eno12399, netdevice)
    c. SriovNetwork (optional NAD in default namespace)
14. Configure PTP:
    a. PtpOperatorConfig
    b. PtpConfig (ordinary clock on eno12399)
15. Apply PerformanceProfile ──────────────► Node reboots (RT kernel)
    (reserved: 0-3,32-35 / isolated: 4-31,36-63 / 4x1G hugepages)
16. Apply TunedPerformancePatch
17. Apply SCTP MachineConfig ──────────────► Node reboots
18. Verify RDS compliance
```

## Appendix B: Key Manifest Changes for RDS

### Diff: `manifests/03-agentclusterinstall.yaml`

```diff
 metadata:
   name: bronco
   namespace: bronco
+  annotations:
+    agent-install.openshift.io/install-config-overrides: '{"cpuPartitioningMode":"AllNodes","capabilities":{"baselineCapabilitySet":"None","additionalEnabledCapabilities":["NodeTuning","OperatorLifecycleManager","Ingress"]}}'
 spec:
   ...
-  installConfigOverrides: '{"capabilities":...}'   # WRONG — not a CRD field, silently ignored
```

### Diff: `manifests/07-managedcluster.yaml` (KlusterletAddonConfig — optional)

```diff
   applicationManager:
-    enabled: true
+    enabled: false
   certPolicyController:
-    enabled: true
+    enabled: false
   iamPolicyController:
-    enabled: true
+    enabled: false
   policyController:
     enabled: true
   searchCollector:
-    enabled: true
+    enabled: false
```

## Appendix C: Lab vs Bronco Differences

| Aspect | Lab Environment | Bronco Environment |
|--------|----------------|-------------------|
| Connectivity | Disconnected (local registry) | Connected (Red Hat CDN) |
| Operator source | `redhat-operator-index` | `redhat-operators` |
| Hardware | KVM VMs (12 vCPUs) | Dell R760 bare metal |
| CPUs | isolated: 4-11, reserved: 0-3 | reserved: 0-3,32-35 / isolated: 4-31,36-63 |
| RT kernel | Disabled (VMs) | Enabled (bare metal) |
| Hugepages | 4 x 1G | 4 x 1G (learning; increase for production) |
| SR-IOV NICs | Virtual igb (vfio passthrough) | Intel E810 25GbE (eno12399), 2 VFs, netdevice |
| PTP | Virtual PTP via igb | Ordinary clock on eno12399 (E810 HW timestamping) |
| Hub OCP version | Same as spoke | 4.18.15 (hub) / 4.20.14 (spoke) |
| Install method | Assisted-service via ArgoCD | Assisted-service via ArgoCD |
| Logging channel | `stable-6.4` | `stable-6.1` (adjust as needed) |
| LVM channel | `stable-4.20` | `stable-4.20` |

## Appendix D: Teardown — Returning Bronco to Bare Metal

Use this procedure to completely destroy the bronco cluster and return the Dell R760
to a powered-off bare metal state, ready for a fresh install. This is useful for
practising the build/wipe cycle.

All commands run from the **jump box** against the **hub cluster**.

### Prerequisites

```bash
ssh -A ajoyce@192.168.38.31
cd /local_home/ajoyce
sudo su

# Get token from https://oauth-openshift.apps.m4.cars2.lab/oauth/token/request
oc login --token=<your-token> --server=https://api.m4.cars2.lab:6443
oc whoami   # should return kube:admin
```

### Step 1: Delete the ManagedCluster

This deregisters bronco from ACM and removes the klusterlet from the spoke. Run
this first so ACM doesn't try to reconcile resources while we're deleting them.

```bash
oc delete managedcluster bronco --wait=true
```

If the ManagedCluster gets stuck in `Terminating`, check for finalizers:

```bash
oc get managedcluster bronco -o jsonpath='{.metadata.finalizers}' && echo
```

If stuck, remove finalizers as a last resort (this orphans the klusterlet on the spoke,
which is fine since we're wiping it):

```bash
oc patch managedcluster bronco --type=merge -p '{"metadata":{"finalizers":[]}}'
```

### Step 2: Delete the ArgoCD Application

Remove the ArgoCD application so it doesn't re-sync and recreate resources. This
**must** be done before deleting the namespace — the app has `selfHeal: true` and
`CreateNamespace=true`, so it will recreate everything if left running.

> **Important:** Use `applications.argoproj.io` — plain `application` hits the
> wrong API group (`app.k8s.io`) and will report `NotFound`.

```bash
oc delete applications.argoproj.io cars2-clusters-bronco -n openshift-gitops --wait=true
```

Verify it's gone:

```bash
oc get applications.argoproj.io -n openshift-gitops | grep bronco
```

### Step 3: Delete the bronco namespace

This removes all Assisted Installer resources (ClusterDeployment, AgentClusterInstall,
InfraEnv, BareMetalHost, Agents, Secrets). The BareMetalHost controller will power off
the Dell R760 via iDRAC as part of deprovisioning.

```bash
oc delete project bronco
```

Wait for the namespace to fully terminate:

```bash
watch oc get project bronco
```

Once it returns `NotFound`, the teardown is complete. If the namespace gets stuck in
`Terminating`, check for stuck finalizers:

```bash
oc get namespace bronco -o jsonpath='{.spec.finalizers}' && echo
oc get all -n bronco
oc get agents -n bronco
oc get bmh -n bronco
```

Common causes of stuck namespaces:
- **BareMetalHost stuck deprovisioning** — the iDRAC may be unreachable. Check BMC
  connectivity (`curl -k https://192.168.38.208/redfish/v1/`). If unreachable, delete
  the BMH with finalizer removal:
  ```bash
  oc patch bmh bronco -n bronco --type=merge -p '{"metadata":{"finalizers":[]}}'
  ```
- **Agent resource with finalizer** — remove it:
  ```bash
  oc get agents -n bronco -o name | xargs -I{} oc patch {} -n bronco --type=merge -p '{"metadata":{"finalizers":[]}}'
  ```

### Step 4: Verify the server is powered off

The BareMetalHost controller should have powered off the server via iDRAC. Verify:

```bash
curl -sk -u root:'RedHatTelco!234' \
  https://192.168.38.208/redfish/v1/Systems/System.Embedded.1 \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Power:', d['PowerState'])"
```

Expected: `Power: Off`

If the server is still on, power it off manually:

```bash
curl -sk -u root:'RedHatTelco!234' \
  -X POST https://192.168.38.208/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset \
  -H 'Content-Type: application/json' \
  -d '{"ResetType": "ForceOff"}'
```

### Step 5: Verify clean state on the hub

```bash
echo "=== Namespace ===" && oc get project bronco 2>/dev/null || echo "Gone"
echo "=== ManagedCluster ===" && oc get managedcluster bronco 2>/dev/null || echo "Gone"
echo "=== ArgoCD App ===" && oc get application cars2-clusters-bronco -n openshift-gitops 2>/dev/null || echo "Gone"
```

All three should report `Gone`.

### Ready to Rebuild

The server is now powered off and all hub resources are cleaned up. To rebuild,
follow the installation steps from `install.md` Step 1, or if you want the full
RDS-compliant build, start from Step 1 in the main body of this document.

Quick rebuild summary:

```bash
# 1. Pull latest manifests
cd /local_home/ajoyce/bronco-sno && git pull origin main

# 2. Create namespace and pull secret
oc create namespace bronco
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d > /tmp/pull-secret.json
oc create secret generic assisted-deployment-pull-secret -n bronco \
  --from-file=.dockerconfigjson=/tmp/pull-secret.json \
  --type=kubernetes.io/dockerconfigjson
rm /tmp/pull-secret.json

# 3. Deploy via ArgoCD
oc apply -k 01-hub-apps/

# 4. Monitor
watch -n 15 'oc get agentclusterinstall bronco -n bronco -o jsonpath="{.status.debugInfo.stateInfo}" && echo && oc get bmh,agents -n bronco && oc get managedcluster bronco'
```

## Appendix E: Troubleshooting Guide

This appendix documents every issue encountered during bronco builds, with
symptoms, root causes, and fixes. Issues are grouped by phase.

---

### Phase 1: Hub Login and CLI Access

#### Problem: `oc login` fails — "You must obtain an API token"

**Symptom:**
```
oc login https://api.m4.cars2.lab:6443
Error: You must obtain an API token by visiting...
```

**Cause:** The hub uses OAuth token-based authentication, not username/password
from the CLI.

**Fix:** Get a token from the web console and use it:
```bash
# Get token from: https://oauth-openshift.apps.m4.cars2.lab/oauth/token/request
oc login --token=<your-token> --server=https://api.m4.cars2.lab:6443
```

Or use a saved service account token:
```bash
oc login --token=$(cat /local_home/ajoyce/hub-token) --server=https://api.m4.cars2.lab:6443 --insecure-skip-tls-verify
```

#### Problem: Commands fail with "Missing or incomplete configuration info"

**Symptom:**
```
error: Missing or incomplete configuration info. Please point to an existing, complete config file
```

**Cause:** The `KUBECONFIG` environment variable is set to a file that is
empty, stale, or was overwritten.

**Fix:** Unset `KUBECONFIG` and re-authenticate:
```bash
unset KUBECONFIG
oc login --token=<your-token> --server=https://api.m4.cars2.lab:6443
```

#### Problem: Commands hit the wrong cluster (hub vs spoke)

**Symptom:** You expect to see the bronco node but see `supervisor1/2/3`, or
you expect hub resources but get `NotFound` errors.

**Cause:** `KUBECONFIG` is pointing at the wrong cluster.

**Fix:** Always check which cluster you're on:
```bash
oc get nodes    # bronco = spr760-1.bronco.cars2.lab, hub = supervisor1/2/3
oc whoami       # check identity
```

To switch to bronco spoke:
```bash
unset KUBECONFIG
oc login --token=$(cat /local_home/ajoyce/hub-token) --server=https://api.m4.cars2.lab:6443 --insecure-skip-tls-verify
oc get secret bronco-admin-kubeconfig -n bronco -o jsonpath='{.data.kubeconfig}' | base64 -d > ~/bronco-kubeconfig
export KUBECONFIG=~/bronco-kubeconfig
```

To switch back to hub:
```bash
unset KUBECONFIG
oc login --token=$(cat /local_home/ajoyce/hub-token) --server=https://api.m4.cars2.lab:6443 --insecure-skip-tls-verify
```

#### Problem: `git` commands fail with "dubious ownership"

**Symptom:**
```
fatal: detected dubious ownership in repository at '/local_home/ajoyce/bronco-sno'
```

**Cause:** Running `git` as root (`sudo su`) on a repo owned by `ajoyce`.

**Fix:** Either run git commands as `ajoyce` (before `sudo su`), or add a
safe directory exception:
```bash
git config --global --add safe.directory /local_home/ajoyce/bronco-sno
```

---

### Phase 2: Install-Time Configuration (AgentClusterInstall)

#### Problem: `installConfigOverrides` spec field is silently ignored

**Symptom:** You add `installConfigOverrides` as a field under `spec:` in
`AgentClusterInstall`, Kubernetes accepts it, but post-install the settings
(cpuPartitioningMode, capability trimming) are not applied.

**Cause:** The `installConfigOverrides` field does **not exist** in the
`AgentClusterInstall` CRD on MCE 2.9.x. Kubernetes silently accepts unknown
spec fields but the assisted-service controller ignores them.

**Fix:** Use the **annotation** instead:
```yaml
metadata:
  annotations:
    agent-install.openshift.io/install-config-overrides: '{"capabilities":{"baselineCapabilitySet":"None","additionalEnabledCapabilities":["NodeTuning","OperatorLifecycleManager","Ingress"]}}'
```

**How to verify the CRD doesn't have the field:**
```bash
oc explain agentclusterinstall.spec --recursive 2>/dev/null | grep -i override
```

#### Problem: Capability validation error — "marketplace requires OperatorLifecycleManager"

**Symptom:**
```
the marketplace capability requires the OperatorLifecycleManager capability
```

**Cause:** `marketplace` depends on `OperatorLifecycleManager`. If you list
`marketplace` in `additionalEnabledCapabilities`, you must also include `OperatorLifecycleManager`.

**Fix:** Either add `OperatorLifecycleManager` alongside `marketplace`, or
remove `marketplace` entirely (it's not required by the telco RDS).

#### Problem: Capability validation error — "the Ingress capability is required"

**Symptom:**
```
the Ingress capability is required
```

**Cause:** `Ingress` is a mandatory capability — the OCP installer rejects any
configuration that omits it.

**Fix:** Always include `Ingress` in `additionalEnabledCapabilities`. The
minimum viable set for telco RDS is:
```json
["NodeTuning", "OperatorLifecycleManager", "Ingress"]
```

#### Problem: Workload partitioning not applied despite annotation

**Symptom:** Post-install, the node has no `node.workload.openshift.io/management`
annotation, and `cpuPartitioningMode` was in the `install-config-overrides` annotation.

**Cause:** The MCE 2.9.x assisted-service does not support `cpuPartitioningMode`
through the `install-config-overrides` annotation. It is stripped or ignored.

**Known limitation:** Workload partitioning requires either:
- The **ZTP SiteConfig/ClusterInstance** deployment method
- A newer MCE version with CRD support for `cpuPartitioningMode`

**Do NOT attempt to fix this by injecting CRI-O/kubelet MachineConfigs via
`manifestsConfigMapRefs`** — this causes CRI-O to enforce CPU pinning without
the kubelet and scheduler being aware, leading to a **finalization timeout**
(see next issue).

#### Problem: "Cluster installation timeout while finalizing"

**Symptom:** The install runs for ~5 hours then fails:
```
The installation has failed: Cluster installation timeout while finalizing
```

**Common causes:**

1. **Workload partitioning MachineConfig without cpuPartitioningMode** —
   CRI-O enforces CPU pinning but the kubelet/scheduler don't expect it.
   Cluster operators fail to stabilize. **Fix:** Remove the workload
   partitioning ConfigMap from `manifestsConfigMapRefs`.

2. **Network issues** — The spoke can't reach the hub or required registries.
   Check the agent progress for more detail:
   ```bash
   oc get agentclusterinstall bronco -n bronco -o jsonpath='{.status.conditions}' | python3 -m json.tool
   ```

3. **Hardware issues** — Disk, memory, or NIC problems on the bare metal server.
   Check iDRAC logs.

#### Problem: Newline in annotation causes JSON parse error

**Symptom:**
```
invalid character '\n' in string literal
```

**Cause:** The annotation JSON was pasted across multiple lines in the shell.

**Fix:** The `oc annotate` command or the annotation value in YAML must be a
**single line** with no embedded newlines. If using `oc annotate`:
```bash
oc annotate agentclusterinstall bronco -n bronco \
  agent-install.openshift.io/install-config-overrides='{"capabilities":{"baselineCapabilitySet":"None","additionalEnabledCapabilities":["NodeTuning","OperatorLifecycleManager","Ingress"]}}' \
  --overwrite
```

---

### Phase 3: Teardown and Rebuild

#### Problem: ArgoCD application deletion says "NotFound"

**Symptom:**
```
oc delete application cars2-clusters-bronco -n openshift-gitops
Error from server (NotFound): applications.app.k8s.io "cars2-clusters-bronco" not found
```

**Cause:** Plain `application` resolves to the `app.k8s.io` API group, not
the ArgoCD API group.

**Fix:** Use the fully qualified resource name:
```bash
oc delete applications.argoproj.io cars2-clusters-bronco -n openshift-gitops --wait=true
```

#### Problem: Namespace recreated after deletion (ArgoCD selfHeal)

**Symptom:** You delete the bronco namespace, but it immediately reappears:
```
Error from server (AlreadyExists): namespaces "bronco" already exists
```

**Cause:** The ArgoCD application has `selfHeal: true` and `CreateNamespace=true`.
When it detects the namespace is missing, it recreates everything.

**Fix:** Always delete the ArgoCD application **before** deleting the namespace:
```bash
# 1. Delete ArgoCD app first
oc delete applications.argoproj.io cars2-clusters-bronco -n openshift-gitops --wait=true
# 2. Delete ManagedCluster
oc delete managedcluster bronco --wait=true
# 3. Then delete namespace
oc delete project bronco
```

#### Problem: Namespace stuck in Terminating

**Symptom:** `oc get project bronco` shows `Terminating` indefinitely.

**Cause:** Resources with finalizers (BareMetalHost, Agent) are blocking
namespace deletion, usually because the controller can't complete cleanup
(e.g., iDRAC unreachable for BMH deprovisioning).

**Fix:** Identify and remove stuck finalizers:
```bash
# Check what's blocking
oc get all -n bronco
oc get bmh,agents -n bronco

# Remove BMH finalizer
oc patch bmh spr760-1 -n bronco --type=merge -p '{"metadata":{"finalizers":[]}}'

# Remove Agent finalizers
oc get agents -n bronco -o name | xargs -I{} oc patch {} -n bronco --type=merge -p '{"metadata":{"finalizers":[]}}'
```

#### Problem: Agent state shows "installed" on a fresh rebuild

**Symptom:** After teardown and rebuild, the agent registers and immediately
shows state `installed` instead of `insufficient` → `known` → `installing`.

**Cause:** The assisted-service's internal state (PostgreSQL) retains records
from the previous installation. It recognizes the host by UUID and thinks
it's already installed.

**Fix:** Restart the assisted-service pods on the hub to clear cached state,
then delete the stale agent:
```bash
# On the hub
oc delete pod -l app=assisted-service -n multicluster-engine
oc wait --for=condition=Ready pod -l app=assisted-service -n multicluster-engine --timeout=180s

# Delete the stale agent
oc delete agents -n bronco --all

# Force BMH re-creation by deleting it (ArgoCD will recreate)
oc delete bmh spr760-1 -n bronco
```

---

### Phase 4: Day-2 Operator Installation

#### Problem: No CatalogSource — operators can't install

**Symptom:** Subscriptions are created but CSVs never appear.
```bash
oc get catalogsource -n openshift-marketplace
No resources found in openshift-marketplace namespace.
```

**Cause:** The `marketplace` capability was trimmed. Without it, the
`openshift-marketplace` namespace and default CatalogSources are not
created automatically.

**Fix:** Create them manually (see Step 11b):
```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators
  image: registry.redhat.io/redhat/redhat-operator-index:v4.20
  publisher: Red Hat
  sourceType: grpc
  grpcPodConfig:
    securityContextConfig: restricted
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
```

Wait for the catalog pod: `oc get pods -n openshift-marketplace -w`

#### Problem: Operator Subscription shows ResolutionFailed

**Symptom:**
```bash
oc get sub <name> -n <namespace> -o yaml | grep -A5 status
# Shows: status: "True", type: ResolutionFailed
```

**Cause:** The specified `channel` doesn't exist in the operator index for
this OCP version.

**Fix:** Check available channels and update the subscription:
```bash
# List available channels
oc get packagemanifest <operator-name> -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}' && echo

# Patch the subscription
oc patch sub <sub-name> -n <namespace> --type=merge -p '{"spec":{"channel":"<correct-channel>"}}'
```

Known channel issues for OCP 4.20:
- `cluster-logging`: Use `stable-6.4` (not `stable-6.1`)
- `lvms-operator`: Use `stable-4.20`
- `sriov-network-operator`: Use `stable`
- `ptp-operator`: Use `stable`

#### Problem: "no matching resources found" when waiting for CSV

**Symptom:**
```
oc wait clusterserviceversion -l <label> ... --timeout=900s
error: no matching resources found
```

**Cause:** The CSV hasn't been created yet — OLM needs time to resolve the
subscription, create the InstallPlan, and install the operator.

**Fix:** Wait a minute and retry. Check progress with:
```bash
oc get sub -A                          # Subscriptions present?
oc get installplan -n <namespace>      # InstallPlan created?
oc get csv -n <namespace>              # CSV appearing?
oc get pods -n openshift-marketplace   # Catalog pod healthy?
```

#### Problem: SR-IOV CRDs not found after CSV shows Succeeded

**Symptom:**
```
no matches for kind "SriovOperatorConfig" in version "sriovnetwork.openshift.io/v1"
ensure CRDs are installed first
```

**Cause:** The CSV succeeded but the operator pods haven't started yet, so CRDs
haven't been registered.

**Fix:** Wait for the operator pods to be running:
```bash
oc get pods -n openshift-sriov-network-operator -w
oc get crd | grep sriov
```

Once pods are running and CRDs exist, retry the `oc apply`.

---

### Phase 5: Day-2 Configuration

#### Problem: Heredoc YAML fails with "could not find expected ':'"

**Symptom:**
```
error: error parsing STDIN: error converting YAML to JSON: yaml: line 10: could not find expected ':'
```

**Cause:** Leading spaces before `---` document separators or top-level YAML
keys. In a heredoc, the YAML content must not have extra indentation on
the top-level keys.

**Fix:** Ensure `apiVersion`, `kind`, `metadata`, `spec`, `---`, and `EOF`
all start at **column 0** with no leading spaces:
```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: example
EOF
```

**Wrong** (extra spaces before apiVersion and EOF):
```bash
oc apply -f - <<'EOF'
  apiVersion: v1
  kind: ConfigMap
  ...
  EOF          # ← indented EOF won't close the heredoc
```

#### Problem: Heredoc doesn't close — shell shows ">" prompt

**Symptom:** After pasting a heredoc command, the shell shows `>` and waits
for more input instead of executing.

**Cause:** The closing `EOF` has leading spaces, or wasn't included in the
paste.

**Fix:** Type `EOF` at column 0 and press Enter. Or `Ctrl+C` to cancel and
repaste the entire block, ensuring `EOF` is at the start of the line.

#### Problem: `nft_compat` kernel warning after RT kernel reboot

**Symptom:** Console shows warnings about the `nft_compat` driver during boot.

**Cause:** This is a known kernel message in RHCOS with the RT kernel, related
to the netfilter compatibility layer.

**Fix:** Ignore it — it's harmless and doesn't affect cluster operation.

#### Problem: MCP stuck updating after MachineConfig changes

**Symptom:** `oc get mcp master` shows `UPDATING=True` for a long time.

**Cause:** MachineConfig changes trigger a node reboot. On SNO there's only one
node, so the entire cluster goes down during the update.

**Fix:** Wait for the node to reboot and come back. Monitor with:
```bash
oc wait mcp master --for='condition=Updated=True' --timeout=1200s
```

If it stays stuck for more than 20 minutes, check:
```bash
oc get nodes                            # Is the node Ready?
oc get mcp master -o yaml | grep -A5 conditions
oc debug node/<node> -- chroot /host journalctl -u kubelet --no-pager | tail -50
```

---

### General Debugging Commands

```bash
# Check install status
oc get agentclusterinstall bronco -n bronco -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Check agent validation
oc get agent -n bronco -o jsonpath='{.items[0].status.validationsInfo}' | python3 -m json.tool

# Check assisted-service logs on hub
oc logs -n multicluster-engine deployment/assisted-service --tail=100

# Check what annotation was applied
oc get agentclusterinstall bronco -n bronco \
  -o jsonpath='{.metadata.annotations.agent-install\.openshift\.io/install-config-overrides}' && echo

# Check MCP render status
oc get mcp master -o yaml | grep -A10 conditions

# Check operator pod status across all operator namespaces
for ns in openshift-sriov-network-operator openshift-ptp openshift-logging openshift-storage; do
  echo "=== $ns ===" && oc get pods -n $ns 2>/dev/null
done

# Full RDS verification (Step 18)
echo "Capabilities:" && oc get clusterversion version -o jsonpath='{.status.capabilities.enabledCapabilities}' | python3 -m json.tool
echo "PerformanceProfile:" && oc get performanceprofile
echo "SR-IOV:" && oc get sriovnetworknodepolicy -n openshift-sriov-network-operator
echo "PTP:" && oc get ptpconfig -n openshift-ptp
echo "MCP:" && oc get mcp master
echo "Console:" && oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' && echo
echo "Network diag:" && oc get network.operator cluster -o jsonpath='{.spec.disableNetworkDiagnostics}' && echo
echo "SCTP:" && oc get machineconfig | grep sctp
```
