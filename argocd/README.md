# Rent-a-Ride on Argo CD

Argo CD manages the deployment of `helm/rent-a-ride` from git, and Argo CD
Image Updater watches the `backend` and `frontend` images on Docker Hub and
commits new tags/digests straight into `helm/rent-a-ride/values.yaml` when
they change - the same file `helm lint`/`helm template` already read
directly (see the remediation report, section 14), so there's no
Argo CD-only state anywhere: `git log` on `values.yaml` is a complete,
human-readable history of every image that's ever been deployed.

## Layout

- `install/install-argocd.sh` - installs Argo CD and Argo CD Image Updater
  on a fresh cluster.
- `image-updater/config.yaml` - Image Updater ConfigMap overrides (log
  level, git commit identity for its write-back commits).
- `image-updater/git-write-back-secret.yaml.example` - reference-only
  shape for the git credentials Image Updater needs to push to this repo.
  Never applied as-is; see below.
- `applications/rent-a-ride.yaml` - the Argo CD Application, including the
  Image Updater annotations that wire it up to the Helm chart.
- `applications/image-updater.yaml` - the `ImageUpdater` custom resource
  that tells the current CRD-driven Image Updater controller to actually
  manage `rent-a-ride` via its annotations (see "A note on Image Updater's
  architecture" below).

## Fresh-cluster setup

1. **Install Argo CD and Image Updater:**

   ```
   ./argocd/install/install-argocd.sh
   ```

   This creates the `argocd` namespace, installs both controllers from
   their official upstream manifests, waits for them to roll out, and
   applies `image-updater/config.yaml` on top.

2. **Create the git write-back credentials Secret.** Image Updater needs
   push access to this repo to commit updated image tags into
   `values.yaml`. This is never checked into git as a real Secret - same
   rule this repo already follows for `mongo-credentials` and
   `backend-secret` (see the remediation report, INC-036). Create it
   imperatively:

   ```
   kubectl create secret generic git-creds \
     -n argocd \
     --from-literal=username=<your-github-username> \
     --from-literal=password=<your-fine-grained-PAT>
   ```

   The PAT needs `Contents: Read and write` on this repo only
   (fine-grained token), so Image Updater can push a commit to the
   `feature/hunter` branch.

3. **Apply the Application and the ImageUpdater CR:**

   ```
   kubectl apply -f argocd/applications/rent-a-ride.yaml
   kubectl apply -f argocd/applications/image-updater.yaml
   ```

   Argo CD will sync `helm/rent-a-ride` into the `rent-a-ride` namespace
   (created by the chart's own `namespace.yaml` template, same as under
   plain `helm install` - see `destination.namespace` in the Application
   for why `CreateNamespace` is deliberately left off). The `ImageUpdater`
   CR is what actually turns on annotation-based tracking for this
   Application - see the note below on why that's a separate object now.

4. **The Secrets the chart itself needs** (`mongo-credentials`,
   `backend-secret`) are still created the same way they always have
   been - Argo CD syncing the Helm chart doesn't change that. See the
   main `README.md`'s Fresh Install section.

5. **(Optional) Log in to the Argo CD UI/CLI:**

   ```
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo
   argocd login <argocd-server-address> --username admin
   ```

## A note on Image Updater's architecture

The Image Updater install manifest changed shape after this repo was first
set up: the current `stable` release is a rewritten, CRD-driven controller
(`quay.io/argoprojlabs/argocd-image-updater:v1.2.2` at the time of writing)
rather than the older controller that acted directly on any Application
carrying its annotations. Two visible differences that tripped up the
first install attempt on this repo:

- The manifest moved from `manifests/install.yaml` to `config/install.yaml`
  - the old URL now 404s.
- The controller Deployment is now named
  `argocd-image-updater-controller`, not `argocd-image-updater`.

Functionally, nothing about the annotation-based setup in this repo had to
change: the new controller only manages Applications that are matched by
an `ImageUpdater` custom resource, but `useAnnotations: true` on that CR
(see `applications/image-updater.yaml`) tells it to keep reading the
per-image configuration from the Application's own
`argocd-image-updater.argoproj.io/*` annotations, exactly as before -
the CR is just the new on-switch, not a second place to configure images.

## How the image-update-to-values.yaml write-back works

Each annotation on the Application in `applications/rent-a-ride.yaml`
does one job:

- `image-list` — declares the two images to watch, aliased `backend` and
  `frontend` so the rest of the annotations can refer to them by name
  instead of repeating the full image path.
- `<alias>.update-strategy: digest` — both images are always pushed as
  `:latest` by the Jenkins pipeline, so there's no version string to
  compare; `digest` tracks the actual image content behind that tag
  instead.
- `write-back-method: git:secret:argocd/git-creds` — write the change as
  a git commit (using the Secret from step 2), not just as an
  Argo CD-internal parameter override.
- `write-back-target: helmvalues:values.yaml` — write directly into the
  chart's own `values.yaml`, in the same `backend.image.tag` /
  `frontend.image.tag` shape the chart already expects.
- `<alias>.helm.image-name` / `<alias>.helm.image-tag` — the exact
  `values.yaml` key paths to update for each image (`backend.image.repository`
  / `backend.image.tag`, and the `frontend.*` equivalents).

When Image Updater detects a new digest behind `:latest` for either
image, it commits the updated tag/digest into `values.yaml` on
`feature/hunter`, and Argo CD's `selfHeal` then picks up that git change
and rolls the corresponding Deployment automatically - no manual
`kubectl rollout restart` needed.

## Known limitation, not yet automated

Because the write-back target is the same branch Argo CD syncs from,
every automatic image update produces a new commit on `feature/hunter`
authored by `argocd-image-updater` (see `image-updater/config.yaml` for
its commit identity). This is intentional - it keeps `values.yaml` as the
single source of truth - but it does mean the CI pipeline's own commits
and Image Updater's commits interleave on the same branch. If that ever
becomes noisy, the standard fix is a dedicated write-back branch with a
PR/merge step in between, which Image Updater also supports via the
`git-branch` annotation - not set up here to keep the first pass simple.
