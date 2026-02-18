# Bronco SNO Cluster Installation Guide

This document captures the full process for deploying the Bronco Single Node OpenShift (SNO) cluster on the `cars2.lab` environment using the MCE SiteConfig operator and ArgoCD from an ACM hub cluster.

## Environment Overview

| Component | Detail |
|-----------|--------|
| Hub cluster | m4.cars2.lab (OCP 4.18, 3-node compact) |
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

### Hub Memory Capacity

The m4 hub is a compact 3-node cluster and can be memory-constrained. If the assisted-service pods are stuck in `Pending`, disable unnecessary MCE components to free resources:

```bash
oc patch multiclusterengine multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift","enabled":false},{"name":"hypershift-local-hosting","enabled":false}]}}}'
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
│   ├── bmh-secret.yaml            # BMC credentials for iDRAC
│   ├── namespace.yaml             # bronco namespace
│   ├── pull-secret.yaml           # Red Hat pull secret (placeholder)
│   └── kustomization.yaml
├── 01-hub-apps/
│   ├── cars2-clusters-bronco-app.yaml   # ArgoCD Application
│   └── kustomization.yaml
├── bronco-clusterinstance.yaml    # ClusterInstance CR for the SNO cluster
├── bronco-siteconfig.yaml         # Legacy SiteConfig (kept for reference)
├── cis-4.16.yaml                  # Legacy ClusterImageSet (not used)
├── kustomization.yaml             # Top-level kustomization
└── install.md                     # This file
```

## Key Design Decision: SiteConfig v1 vs ClusterInstance

The original novacain1 repo used the **legacy SiteConfig** (`ran.openshift.io/v1`) approach, which requires a ZTP kustomize generator plugin installed in the ArgoCD repo-server. This plugin was not configured on the m4 hub and is the older approach.

Starting with MCE 2.7+ (OCP 4.17+), the recommended approach is the **ClusterInstance** CR (`siteconfig.open-cluster-management.io/v1alpha1`), which is processed by the SiteConfig operator built into MCE. This is a standard Kubernetes resource that ArgoCD can sync directly -- no plugins needed.

**Key differences:**
- `SiteConfig` uses a `spec.clusters[]` array and acts as a kustomize generator
- `ClusterInstance` is a flat CR with cluster config directly in `spec` and is a regular resource
- `ClusterInstance` is applied as a standard kustomize resource, not a generator

## YAML Changes Made

### 1. Converted SiteConfig to ClusterInstance

Created `bronco-clusterinstance.yaml` using the `siteconfig.open-cluster-management.io/v1alpha1` API. All networking, BMC, and node configuration was preserved from the original SiteConfig. The ClusterImageSet was updated to 4.20:

```yaml
apiVersion: siteconfig.open-cluster-management.io/v1alpha1
kind: ClusterInstance
metadata:
  name: bronco
  namespace: bronco
spec:
  clusterImageSetNameRef: img4.20.14-x86-64-appsub
  # ... all cluster config directly in spec (not nested under clusters[])
```

### 2. Updated kustomization.yaml

Changed from generator to resource:

```yaml
# Before (legacy SiteConfig approach)
generators:
  - bronco-siteconfig.yaml

# After (ClusterInstance approach)
resources:
  - bronco-clusterinstance.yaml
```

### 3. ArgoCD Application: Repo URL and project updated

In `01-hub-apps/cars2-clusters-bronco-app.yaml`:

```yaml
# Before
project: ztp-app-project
source:
  path: rhocp-clusters/bronco.cars2.lab
  repoURL: https://github.com/novacain1/carslab-public

# After
project: default
source:
  path: .
  repoURL: https://github.com/apj72/bronco-sno
```

The `ztp-app-project` did not exist on the m4 hub, so `default` is used instead.

### 4. Added AgentServiceConfig

Created `00-hub-prereqs/agentserviceconfig.yaml` to deploy the assisted-service, which was not running on the hub. Uses `lso-filesystemclass` storage.

## ClusterInstance Key Details

The ClusterInstance (`bronco-clusterinstance.yaml`) defines the full SNO deployment:

- **Cluster name:** bronco
- **Base domain:** cars2.lab (API will be at `api.bronco.cars2.lab`)
- **Network plugin:** OVNKubernetes
- **CPU partitioning:** AllNodes (for telco/DU workloads)
- **Capability trimming:** Minimal baseline with only `marketplace` and `NodeTuning`
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

## Installation Steps

### Step 1: Log in to the hub cluster

SSH to the jump box, then log in to the hub:

```bash
ssh -A ajoyce@192.168.38.31
oc login https://api.m4.cars2.lab:6443
oc whoami   # should return kube:admin
```

### Step 2: Clone the repo on the jump box

```bash
git clone https://github.com/apj72/bronco-sno.git /local_home/ajoyce/bronco-sno
cd /local_home/ajoyce/bronco-sno
```

### Step 3: Check for existing bronco namespace

If re-deploying, ensure no stale namespace exists:

```bash
oc get project bronco 2>/dev/null && echo "EXISTS" || echo "NOT FOUND"
```

If it exists from a previous attempt, clean it up before proceeding.

### Step 4: Ensure assisted-service is running

```bash
oc get agentserviceconfig
oc get pods -n multicluster-engine | grep assisted
```

If the AgentServiceConfig doesn't exist, create it:

```bash
oc apply -f 00-hub-prereqs/agentserviceconfig.yaml
```

Wait for both `assisted-service` and `assisted-image-service` pods to be Running and Ready.

### Step 5: Apply hub prerequisites

Create the `bronco` namespace and BMC secret:

```bash
cd /local_home/ajoyce/bronco-sno
oc apply -k 00-hub-prereqs/
```

Expected output:
```
namespace/bronco created
secret/bronco-bmc-creds-secret created
```

### Step 6: Create the pull secret

The pull secret is not included in the repo for security reasons. Copy the hub's existing pull secret into the `bronco` namespace:

```bash
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/pull-secret.json
oc create secret generic assisted-deployment-pull-secret -n bronco --from-file=.dockerconfigjson=/tmp/pull-secret.json --type=kubernetes.io/dockerconfigjson
rm /tmp/pull-secret.json
```

Verify both secrets exist:

```bash
oc get secrets -n bronco
```

Expected output should show both `assisted-deployment-pull-secret` and `bronco-bmc-creds-secret`.

### Step 7: Apply the ArgoCD Application

This triggers ArgoCD to sync the ClusterInstance from Git:

```bash
cd /local_home/ajoyce/bronco-sno
oc apply -k 01-hub-apps/
```

Verify the ArgoCD application is syncing:

```bash
oc get applications.argoproj.io cars2-clusters-bronco -n openshift-gitops
```

Expected: `SYNC STATUS: Synced`, `HEALTH STATUS: Healthy`

### Step 8: Monitor the installation

Watch the cluster deployment progress:

```bash
# Check the ClusterInstance status
oc get clusterinstance bronco -n bronco

# Check the AgentClusterInstall status
oc get agentclusterinstall -n bronco

# Watch for the BareMetalHost to be provisioned
oc get bmh -n bronco

# Watch for the agent to register
oc get agents -n bronco

# Monitor overall cluster deployment
oc get managedcluster bronco
```

## Installation Flow Summary

1. ArgoCD syncs the Git repo and applies the ClusterInstance CR
2. The SiteConfig operator (MCE) processes the ClusterInstance and creates the underlying resources (ClusterDeployment, AgentClusterInstall, BareMetalHost, NMStateConfig, etc.)
3. The assisted-service generates an ISO discovery image
4. The hub powers on the server via iDRAC/Redfish and boots from the ISO
5. The assisted installer agent registers with the hub
6. Installation proceeds automatically
7. Once complete, the cluster is imported as a managed cluster
8. Hub policies (matched by cluster labels) apply day-2 configuration

## Troubleshooting

### ArgoCD sync shows "Unknown"

Check the application status for errors:

```bash
oc get applications.argoproj.io cars2-clusters-bronco -n openshift-gitops -o yaml | tail -30
```

Common issues:
- **"external plugins disabled; unable to load external plugin 'SiteConfig'"** -- You're using the legacy SiteConfig format. Convert to ClusterInstance (see above).
- **"Application referencing project X which does not exist"** -- Update the ArgoCD Application to use an existing project (e.g., `default`).

### Assisted-service pods stuck in Pending

Check for scheduling issues:

```bash
oc describe pod <pod-name> -n multicluster-engine | tail -20
```

Common causes:
- **Memory pressure** -- Disable unnecessary MCE components (hypershift, discovery)
- **Disk pressure** -- Check node disk usage
- **Volume affinity conflict** -- LSO PVs are node-specific; the pod must schedule on the node where PVs are bound
