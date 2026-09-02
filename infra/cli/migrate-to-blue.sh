#!/usr/bin/env bash
# One-time migration: moves the currently-live "rent-a-ride" namespace
# release into "blue", so it becomes the stable side of a blue/green setup.
# Run this BEFORE infra/cli/blue-green-setup.sh.
#
# This causes a short outage (roughly the time it takes helm to uninstall
# the old release and the new blue pods to become Ready) because blue
# reuses the exact same NodePorts (30080/30300) that "rent-a-ride" is
# currently bound to - Kubernetes won't let two Services claim the same
# NodePort at once, so the old release has to come down before blue can
# come up. If you need zero downtime for this specific step, stand up
# blue on temporary alternate NodePorts first, verify it, then repeat the
# swap - not scripted here since it's a one-time migration, not a
# repeatable path.
#
# Assumes: the live app is running in namespace "rent-a-ride" - either as
# a Helm release, or applied directly via `kubectl apply -k k8s/` (both are
# detected and handled). mongo-credentials and backend-secret must already
# be present in that namespace.

set -euo pipefail

OLD_NAMESPACE="rent-a-ride"
NEW_NAMESPACE="blue"
CHART_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../helm/rent-a-ride" && pwd)"
VALUES_FILE="${CHART_PATH}/environments/values-blue.yaml"

echo "== Finding the live app in namespace ${OLD_NAMESPACE} =="

OLD_RELEASE=$(helm list -n "$OLD_NAMESPACE" -q 2>/dev/null | head -n1 || true)

if [[ -n "$OLD_RELEASE" ]]; then
  DEPLOY_METHOD="helm"
  echo "Live release: ${OLD_RELEASE} (Helm, namespace ${OLD_NAMESPACE})"
elif kubectl get deployment backend frontend -n "$OLD_NAMESPACE" >/dev/null 2>&1; then
  DEPLOY_METHOD="kubectl"
  echo "Live app found in ${OLD_NAMESPACE}, but not installed via Helm"
  echo "(likely applied directly with 'kubectl apply -k k8s/' - that's fine,"
  echo " this script will just delete the namespace instead of 'helm uninstall')."
else
  echo "No app found in namespace ${OLD_NAMESPACE} (neither a Helm release nor" >&2
  echo "backend/frontend Deployments). Nothing to migrate." >&2
  exit 1
fi

echo "== Copying Secrets (mongo-credentials, backend-secret) into ${NEW_NAMESPACE} =="

kubectl create namespace "$NEW_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

copy_secret () {
  local name="$1"
  if ! kubectl get secret "$name" -n "$OLD_NAMESPACE" >/dev/null 2>&1; then
    echo "  (secret '${name}' not found in ${OLD_NAMESPACE} - skipping; create it manually in ${NEW_NAMESPACE} if needed)"
    return
  fi
  kubectl get secret "$name" -n "$OLD_NAMESPACE" -o json \
    | jq --arg ns "$NEW_NAMESPACE" '
        del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
            .metadata.selfLink, .metadata.managedFields, .metadata.ownerReferences)
        | .metadata.namespace = $ns
      ' \
    | kubectl apply -f -
  echo "  copied secret/${name} -> ${NEW_NAMESPACE}"
}

copy_secret mongo-credentials
copy_secret backend-secret

echo "== Removing the old ${OLD_NAMESPACE} deployment (frees NodePorts 30080/30300 for blue) =="

if [[ "$DEPLOY_METHOD" == "helm" ]]; then
  helm uninstall "$OLD_RELEASE" -n "$OLD_NAMESPACE"
else
  # Delete the NodePort-holding Services explicitly first and wait for them
  # to actually go away, since NodePort release happens on Service
  # deletion, not on namespace deletion (which can take a while longer if
  # anything in the namespace has finalizers).
  kubectl delete service frontend backend-external -n "$OLD_NAMESPACE" --ignore-not-found --wait=true
  kubectl delete namespace "$OLD_NAMESPACE"
  echo "(namespace deletion requested - it may finish terminating in the background;"
  echo " the NodePorts themselves are already free since their Services are gone)"
fi

# Give the API server a moment to actually release the NodePort allocation.
sleep 5

echo "== Installing blue (same chart, same image tags as the old release's values.yaml) =="

helm install rent-a-ride-blue "$CHART_PATH" \
  -n "$NEW_NAMESPACE" --create-namespace \
  -f "$VALUES_FILE"

echo "== Waiting for blue's Deployments to roll out =="

kubectl -n "$NEW_NAMESPACE" rollout status deployment/backend --timeout=180s
kubectl -n "$NEW_NAMESPACE" rollout status deployment/frontend --timeout=180s
kubectl -n "$NEW_NAMESPACE" rollout status statefulset/mongo --timeout=180s || true

echo
echo "Done. 'blue' is now live on NodePorts 30080 (frontend) / 30300 (backend),"
echo "matching what the ALB already targets. Verify directly:"
echo "  curl http://localhost:30080/"
echo "  curl http://localhost:30300/healthz"
echo
if [[ "$DEPLOY_METHOD" == "helm" ]]; then
  echo "Old namespace '${OLD_NAMESPACE}' is now empty (release uninstalled) but"
  echo "not deleted - remove it once you've confirmed blue is healthy:"
  echo "  kubectl delete namespace ${OLD_NAMESPACE}"
  echo
fi
echo "Next: run infra/cli/blue-green-setup.sh to wire the ALB's target groups"
echo "to blue (and pre-create green's), then deploy a new version to green"
echo "per docs/blue-green-deployment.md."
