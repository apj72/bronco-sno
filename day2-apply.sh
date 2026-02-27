#!/bin/bash
#
# Applies all Telco RDS day-2 configuration to the Bronco SNO spoke cluster.
# Run this from the jump box with KUBECONFIG pointing at bronco.
#
# Usage:
#   export KUBECONFIG=~/bronco-kubeconfig
#   ./day2-apply.sh
#
# Prerequisites:
#   - Bronco SNO is installed and accessible
#   - KUBECONFIG is set to the bronco spoke cluster
#
# What this script does (Steps 9-17 from Telco_RDS_spoke_install.md):
#   1. Reduces monitoring footprint (24h retention, disable alertmanager/telemeter)
#   2. Disables Console Operator
#   3. Disables SNO network diagnostics
#   4. Creates CatalogSource (required because marketplace capability is trimmed)
#   5. Installs SR-IOV, PTP, Logging, and LVM Storage operators
#   6. Configures SR-IOV (operator config, node policy, network)
#   7. Configures PTP (operator config, ordinary clock on eno12399)
#   8. Applies PerformanceProfile (triggers node reboot)
#   9. Applies TunedPerformancePatch
#  10. Applies SCTP MachineConfig (triggers node reboot)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [ -z "${KUBECONFIG:-}" ]; then
  error "KUBECONFIG is not set. Point it at the bronco spoke cluster first."
fi

NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || error "Cannot reach cluster. Check KUBECONFIG."
info "Connected to bronco spoke — node: $NODE"

# ── Step 9: Reduce Monitoring Footprint ──────────────────────────────────────
info "Step 9: Reducing monitoring footprint..."
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

# ── Step 10: Disable Console Operator ────────────────────────────────────────
info "Step 10: Disabling Console Operator..."
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

# ── Step 11: Disable SNO Network Diagnostics ─────────────────────────────────
info "Step 11: Disabling network diagnostics..."
oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  disableNetworkDiagnostics: true
EOF

# ── Step 11b: Create CatalogSource ───────────────────────────────────────────
info "Step 11b: Creating CatalogSource (marketplace capability is trimmed)..."
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

info "Waiting for catalog pod to be ready..."
oc wait pod -l olm.catalogSource=redhat-operators -n openshift-marketplace \
  --for=condition=Ready --timeout=300s

# ── Step 12: Deploy Day-2 Operators ──────────────────────────────────────────
info "Step 12a: Installing SR-IOV Operator..."
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

info "Step 12b: Installing PTP Operator..."
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

info "Step 12c: Installing Cluster Logging Operator..."
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

info "Step 12d: Installing LVM Storage Operator..."
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

info "Step 12e: Waiting for all operators to install (this may take several minutes)..."

for op in \
  "openshift-sriov-network-operator:operators.coreos.com/sriov-network-operator.openshift-sriov-network-operator:SR-IOV" \
  "openshift-ptp:operators.coreos.com/ptp-operator.openshift-ptp:PTP" \
  "openshift-logging:operators.coreos.com/cluster-logging.openshift-logging:Logging" \
  "openshift-storage:operators.coreos.com/lvms-operator.openshift-storage:LVM Storage"; do
  NS=$(echo "$op" | cut -d: -f1)
  LABEL=$(echo "$op" | cut -d: -f2)
  NAME=$(echo "$op" | cut -d: -f3)
  info "  Waiting for $NAME operator..."
  until oc -n "$NS" wait clusterserviceversion -l "$LABEL" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null; do
    sleep 10
  done
done
info "All operators installed."

# ── Step 13: Configure SR-IOV ────────────────────────────────────────────────
info "Step 13a: Applying SriovOperatorConfig..."
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

info "Step 13b: Applying SriovNetworkNodePolicy (2 VFs on eno12399)..."
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

info "Step 13c: Applying SriovNetwork..."
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

# ── Step 14: Configure PTP ───────────────────────────────────────────────────
info "Step 14a: Applying PtpOperatorConfig..."
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

info "Step 14b: Applying PtpConfig (ordinary clock on eno12399)..."
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

# ── Step 15: PerformanceProfile (triggers node reboot) ───────────────────────
info "Step 15: Applying PerformanceProfile (node will reboot — RT kernel, CPU isolation, hugepages)..."
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

# ── Step 16: TunedPerformancePatch ───────────────────────────────────────────
info "Step 16: Applying TunedPerformancePatch..."
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

# ── Step 17: SCTP MachineConfig (triggers node reboot) ───────────────────────
info "Step 17: Applying SCTP MachineConfig..."
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

# ── Wait for node reboot and stabilisation ───────────────────────────────────
info "Waiting for PerformanceProfile to become Available (node rebooting, ~10-15 min)..."
info "The node will reboot to apply RT kernel, hugepages, CPU isolation, and SCTP."
oc wait --for='jsonpath={.status.conditions[?(@.type=="Available")].status}=True' \
  performanceprofile openshift-node-performance-profile --timeout=1200s

info "Waiting for node to be Ready..."
oc wait node --all --for=condition=Ready --timeout=600s

echo ""
info "═══════════════════════════════════════════════════════════════"
info " Day-2 RDS configuration complete!"
info " Run the verification commands from Step 18 in the install guide."
info "═══════════════════════════════════════════════════════════════"
