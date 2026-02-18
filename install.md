# Bronco SNO Cluster Installation Guide

This document captures the full process for deploying the Bronco Single Node OpenShift (SNO) cluster on the `cars2.lab` environment using ZTP (Zero Touch Provisioning) from an ACM hub cluster.

## Environment Overview

| Component | Detail |
|-----------|--------|
| Hub cluster | m4.cars2.lab |
| Hub console | console-openshift-console.apps.m4.cars2.lab |
| Hub API | api.m4.cars2.lab:6443 |
| SSH access | `ssh -A ajoyce@192.168.38.31` |
| SNO target | Bronco (Dell R760, hostname: spr760-1.bronco.cars2.lab) |
| OCP version | 4.20.14 |
| Git repo | https://github.com/apj72/bronco-sno |

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
│   ├── bmh-secret.yaml          # BMC credentials for iDRAC
│   ├── namespace.yaml           # bronco namespace
│   ├── pull-secret.yaml         # Red Hat pull secret (placeholder)
│   └── kustomization.yaml
├── 01-hub-apps/
│   ├── cars2-clusters-bronco-app.yaml   # ArgoCD Application
│   └── kustomization.yaml
├── bronco-siteconfig.yaml       # Main SiteConfig for the SNO cluster
├── cis-4.16.yaml                # ClusterImageSet (not used - hub already has 4.20)
├── kustomization.yaml           # Top-level kustomization
└── install.md                   # This file
```

## YAML Changes Made

### 1. SiteConfig: ClusterImageSet updated to 4.20

In `bronco-siteconfig.yaml`, the image reference was changed from 4.16 to 4.20:

```yaml
# Before
clusterImageSetNameRef: "img4.16.33-x86-64-appsub"

# After
clusterImageSetNameRef: "img4.20.14-x86-64-appsub"
```

### 2. ArgoCD Application: Repo URL updated

In `01-hub-apps/cars2-clusters-bronco-app.yaml`, the source was updated to point to our repo:

```yaml
# Before
source:
  path: rhocp-clusters/bronco.cars2.lab
  repoURL: https://github.com/novacain1/carslab-public

# After
source:
  path: .
  repoURL: https://github.com/apj72/bronco-sno
```

## SiteConfig Key Details

The SiteConfig (`bronco-siteconfig.yaml`) defines the full SNO deployment:

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

```bash
ssh -A ajoyce@192.168.38.31
oc login https://api.m4.cars2.lab:6443
oc whoami   # should return kube:admin
```

### Step 2: Apply hub prerequisites

Create the `bronco` namespace and BMC secret:

```bash
oc apply -k 00-hub-prereqs/
```

This creates:
- The `bronco` namespace
- The `bronco-bmc-creds-secret` secret (iDRAC credentials)

### Step 3: Create the pull secret

The pull secret is not included in the repo for security reasons. Create it manually in the `bronco` namespace with your Red Hat pull secret:

```bash
oc create secret generic assisted-deployment-pull-secret \
  -n bronco \
  --from-file=.dockerconfigjson=/path/to/your/pull-secret.json \
  --type=kubernetes.io/dockerconfigjson
```

### Step 4: Apply the ArgoCD Application

This triggers the ZTP pipeline:

```bash
oc apply -k 01-hub-apps/
```

### Step 5: Monitor the installation

Watch the cluster deployment progress:

```bash
# Check the AgentClusterInstall status
oc get agentclusterinstall -n bronco -o yaml

# Watch for the BareMetalHost to be provisioned
oc get bmh -n bronco

# Watch for the agent to register
oc get agents -n bronco

# Monitor overall cluster deployment
oc get managedcluster bronco
```

## Installation Flow Summary

1. ArgoCD syncs the Git repo and processes the SiteConfig
2. The ZTP pipeline generates an ISO discovery image
3. The hub powers on the server via iDRAC/Redfish and boots from the ISO
4. The assisted installer agent registers with the hub
5. Installation proceeds automatically
6. Once complete, the cluster is imported as a managed cluster
7. Hub policies (matched by cluster labels) apply day-2 configuration
