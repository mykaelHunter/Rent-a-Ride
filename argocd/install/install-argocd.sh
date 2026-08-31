#!/usr/bin/env bash
# Installs Argo CD and Argo CD Image Updater on a fresh cluster.
#
# This only installs the two controllers and waits for them to come up.
# It does NOT create the git write-back credentials Secret (see
# argocd/image-updater/git-write-back-secret.yaml.example) or apply the
# Application (argocd/applications/rent-a-ride.yaml) - both of those are
# separate, deliberate steps documented in argocd/README.md, following the
# same "never let a placeholder Secret get applied automatically" rule the
# rest of this repo already uses for mongo-credentials/backend-secret (see
# the remediation report, INC-036).
#
# Usage: ./argocd/install/install-argocd.sh
# Requires: kubectl pointed at the target cluster, cluster-admin access.

set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
IMAGE_UPDATER_VERSION="${IMAGE_UPDATER_VERSION:-stable}"

echo "==> Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing Argo CD (${ARGOCD_VERSION})"
# --server-side is required here, not optional: Argo CD's install manifest
# is large enough that plain client-side apply hits the last-applied-
# configuration annotation's size limit on some of these objects.
# --force-conflicts lets this apply take ownership of fields a previous
# run may have set under a different field manager (e.g. a prior
# client-side kubectl apply of the same manifest), so re-running this
# script is always safe to retry.
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> Waiting for Argo CD core components to be ready"
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

echo "==> Installing Argo CD Image Updater (${IMAGE_UPDATER_VERSION})"
# Note: the current "stable" release is a rewritten, CRD-driven controller
# (ImageUpdater custom resource) - a different architecture from the older
# annotation-only controller, and its manifest lives under config/, not
# manifests/. It still honors pure Application annotations (which is what
# this repo uses), but only for Applications matched by an ImageUpdater CR
# with useAnnotations: true - see argocd/applications/image-updater.yaml.
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/${IMAGE_UPDATER_VERSION}/config/install.yaml"

echo "==> Waiting for Argo CD Image Updater to be ready"
kubectl -n argocd rollout status deployment/argocd-image-updater-controller --timeout=300s

echo "==> Applying Image Updater configuration overrides (log level, git commit identity)"
kubectl apply -n argocd --server-side --force-conflicts \
  -f "$(dirname "$0")/../image-updater/config.yaml"

cat <<'EOF'

==> Argo CD and Argo CD Image Updater are installed.

Still required before the app will actually deploy or auto-update:

1. Create the git write-back credentials Secret Image Updater needs to
   push updated image tags/digests back into helm/rent-a-ride/values.yaml.
   See argocd/image-updater/git-write-back-secret.yaml.example for the
   required shape and argocd/README.md for the exact command - this is
   never checked in as a real Secret, same reasoning as mongo-credentials
   and backend-secret elsewhere in this repo.

2. Apply the Application and the ImageUpdater CR that tells the
   controller to manage it via annotations:
     kubectl apply -f argocd/applications/rent-a-ride.yaml
     kubectl apply -f argocd/applications/image-updater.yaml

3. (Optional) Get the initial admin password and log in:
     kubectl -n argocd get secret argocd-initial-admin-secret \
       -o jsonpath='{.data.password}' | base64 -d; echo
     argocd login <argocd-server-address> --username admin

See argocd/README.md for the full walkthrough.
EOF
