# Undo: Re-enable Console on Bronco SNO

After KPI evaluation is complete, reverse the console disable changes.

## 1. Re-enable console on bronco directly

```bash
export KUBECONFIG=/local_home/ajoyce/bronco-sno/auth/kubeconfig
oc patch consoles.operator.openshift.io cluster --type merge -p '{"spec":{"managementState":"Managed"}}'
```

## 2. Remove the ACM policy from the hub

```bash
unset KUBECONFIG  # switch back to hub context
oc delete policy common-du-disable-console -n ztp-policies
```

## 3. Revert bronco-sno repo changes

```bash
cd /Users/ajoyce/git-repos/bronco-sno
git checkout -- 02-day2-policies/placement.yaml
git checkout -- 02-day2-policies/cgu-bronco-day2.yaml
git checkout -- 02-day2-policies/kustomization.yaml
rm 02-day2-policies/policy-disable-console.yaml
```

Then push / sync with ArgoCD as needed.
