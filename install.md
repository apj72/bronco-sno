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
  - Default routes: `192.168.38.129` (v4), `2600:52:7:300::1` (v6)

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
4. The BareMetalHost controller powers on the server via iDRAC/Redfish and boots from the ISO
5. The discovery agent on the server registers with the assisted-service
6. The assisted-service validates the host and begins installation
7. OCP 4.20.14 is installed as a single-node cluster
8. Once complete, the ManagedCluster is registered with ACM
9. Hub policies (matched by cluster labels) apply day-2 configuration

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
