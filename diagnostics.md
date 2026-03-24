# Bronco SNO Diagnostics & Recovery — 17 March 2026

## Problem

The bronco SNO ManagedCluster was showing `Available=Unknown` on the ACM hub (m4.cars2.lab). The hub console could not communicate with the spoke, and the admin credentials (kubeconfig and kubeadmin password secrets) were missing from the hub's `bronco` namespace.

---

## Step 1: Verify hub connectivity

**What:** Confirmed we were logged into the hub cluster and checked the ManagedCluster status.

**Why:** Before diagnosing the spoke, we need to confirm the hub is healthy and see what it reports about bronco.

```bash
export KUBECONFIG=/local_home/ajoyce/crucible-4.20/generated/m4/auth/kubeconfig
oc whoami --show-server
oc get managedcluster bronco
```

**Result:** Hub was healthy. Bronco showed `JOINED=<blank>`, `AVAILABLE=Unknown` — the klusterlet connection was broken.

---

## Step 2: Check AgentClusterInstall status

**What:** Queried the AgentClusterInstall to see if the bronco installation had completed successfully.

**Why:** If the install never completed, the cluster wouldn't be running at all and we'd need a different recovery path.

```bash
oc get agentclusterinstall bronco -n bronco -o jsonpath='{.status.conditions[*].type}{"\n"}{.status.conditions[*].status}{"\n"}{.status.conditions[*].message}{"\n"}'
```

**Result:** Installation completed successfully. The `SpecSynced=False` error about the IP appearing in both apiVIPs and ingressVIPs is expected for SNO (single IP serves both roles).

---

## Step 3: Check BareMetalHost and Agent

**What:** Verified the physical server was powered on and the agent had completed provisioning.

**Why:** If the BMH was powered off or the agent hadn't finished, the SNO wouldn't be reachable.

```bash
oc get bmh -n bronco
oc get agents -n bronco
```

**Result:** BMH `spr760-1` was `provisioned` and `ONLINE=true`. Agent stage was `Done`.

---

## Step 4: Test network reachability and API health

**What:** Pinged the SNO IP and checked the API server health endpoint.

**Why:** Confirms the SNO node is running and the Kubernetes API server is responding, independent of authentication.

```bash
ping -c 2 192.168.38.145
curl -k https://api.bronco.cars2.lab:6443/healthz
```

**Result:** Ping succeeded, API returned `ok`. The SNO cluster was running and healthy — the problem was purely about missing credentials and a broken hub-spoke connection.

---

## Step 5: Attempt to retrieve admin credentials from hub secrets

**What:** Looked for `bronco-admin-kubeconfig` and `bronco-admin-password` secrets in the `bronco` namespace.

**Why:** These secrets are normally created by the assisted-service/hive after installation and are used to access the spoke cluster.

```bash
oc get secrets -n bronco | grep admin
```

**Result:** Neither secret existed. The `ClusterDeployment` also had `installed: false` and no `clusterMetadata` section, which explains why the secrets were never populated despite the installation having completed (a known issue with assisted-service).

---

## Step 6: Attempt SSH access to the SNO

**What:** Tried to SSH to the SNO as `core` user using all available SSH keys on the KVM host.

**Why:** If we could SSH in, we could extract the kubeconfig directly from the node's filesystem at `/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig`.

```bash
for key in /local_home/ajoyce/crucible/ssh_keys/* /local_home/ajoyce/crucible-4.20/ssh_keys/*; do
  [[ "$key" == *.pub ]] && continue
  ssh -i "$key" -o BatchMode=yes core@192.168.38.145 hostname
done
```

**Result:** All keys rejected. The SSH public key baked into the InfraEnv (`id_rsa.rhps`) had its private key missing from the KVM host — only the `.pub` file remained.

---

## Step 7: Retrieve credentials from the assisted-service database

**What:** Accessed the assisted-service pod's local filesystem where installation artifacts are stored.

**Why:** The assisted-service stores kubeconfig and kubeadmin-password files on its filesystem under `/data/<cluster-id>/` after a successful installation, even if the hub secrets were never created.

```bash
CLUSTER_ID="f06e7e40-5435-42ba-9778-ba069494b443"
POD=$(oc get pods -n multicluster-engine -l app=assisted-service -o jsonpath='{.items[0].metadata.name}')

# Get kubeadmin password
oc exec -n multicluster-engine $POD -c assisted-service -- cat /data/$CLUSTER_ID/kubeadmin-password

# Get kubeconfig
oc exec -n multicluster-engine $POD -c assisted-service -- cat /data/$CLUSTER_ID/kubeconfig > ~/bronco-kubeconfig
```

**Result:** Successfully retrieved both the kubeadmin password and a working kubeconfig. Verified with `oc get nodes` — the SNO was `Ready`.

---

## Step 8: Recreate missing admin secrets on the hub

**What:** Created the `bronco-admin-kubeconfig` and `bronco-admin-password` secrets in the `bronco` namespace on the hub.

**Why:** These secrets are expected by ACM/hive for managing the spoke cluster. Without them, operations like `oc get secret bronco-admin-kubeconfig` fail, and the hub cannot proxy commands to the spoke.

```bash
oc create secret generic bronco-admin-kubeconfig -n bronco --from-file=kubeconfig=~/bronco-kubeconfig
oc create secret generic bronco-admin-password -n bronco --from-literal=password='<password>'
```

---

## Step 9: Re-import bronco via auto-import-secret

**What:** Created an `auto-import-secret` containing the bronco kubeconfig in the `bronco` namespace.

**Why:** The ACM import controller watches for a secret named `auto-import-secret` in each managed cluster's namespace. When it finds one containing a valid kubeconfig for the spoke, it uses it to deploy (or redeploy) the klusterlet agent on the spoke. This re-establishes the hub-spoke communication channel without requiring a full reinstall.

```bash
oc create secret generic auto-import-secret -n bronco --from-file=kubeconfig=~/bronco-kubeconfig
```

**Result:** The import controller consumed the secret (it auto-deletes after use), deployed the klusterlet and all addon agents on the SNO. Within seconds the ManagedCluster status changed to `JOINED=True`, `AVAILABLE=True`.

---

## Step 10: Verify recovery

**What:** Confirmed the ManagedCluster was healthy and all klusterlet pods were running on the SNO.

```bash
# From hub
oc get managedcluster bronco

# From SNO
KUBECONFIG=~/bronco-kubeconfig oc get pods -n open-cluster-management-agent
KUBECONFIG=~/bronco-kubeconfig oc get pods -n open-cluster-management-agent-addon
```

**Result:**
- ManagedCluster: `JOINED=True`, `AVAILABLE=True`
- All klusterlet and addon pods running

---

## Credentials Reference

| Item | Location |
|------|----------|
| Bronco kubeadmin password | `oc get secret bronco-admin-password -n bronco -o jsonpath='{.data.password}' \| base64 -d` |
| Bronco kubeconfig (KVM host) | `/root/bronco-kubeconfig` |
| Bronco kubeconfig (hub secret) | `oc get secret bronco-admin-kubeconfig -n bronco -o jsonpath='{.data.kubeconfig}' \| base64 -d` |
| Assisted-service filesystem | `oc exec <assisted-pod> -c assisted-service -- cat /data/f06e7e40-5435-42ba-9778-ba069494b443/kubeadmin-password` |

## Root Cause

The `ClusterDeployment` for bronco was never updated with `clusterMetadata` after installation completed, so hive never created the `bronco-admin-kubeconfig` and `bronco-admin-password` secrets. Additionally, the SSH private key used in the InfraEnv was lost from the KVM host, preventing direct node access. The combination meant there was no obvious way to access the spoke cluster from the hub.

## Lesson Learned

- Always verify that admin secrets exist after an assisted-service installation completes.
- Back up the SSH private key used in the InfraEnv/AgentClusterInstall — if lost, the only fallback is the assisted-service pod's filesystem or BMC console access.
- The assisted-service stores credentials on its local filesystem under `/data/<cluster-id>/` indefinitely (as long as the pod's PV exists), which serves as a last-resort recovery path.
