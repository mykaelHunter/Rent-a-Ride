# Rent-a-Ride — Jenkins CI Setup (GitHub webhook → Docker Hub)

## 1. Plugins to install (Manage Jenkins → Plugins)
- **GitHub** — repo integration, `githubPush()` trigger
- **GitHub Branch Source** — only needed if you switch to a Multibranch Pipeline later
- **Docker Pipeline** — Docker build/push steps usable from the Jenkinsfile
- **Pipeline** (usually preinstalled) — declarative pipeline support
- **Credentials Binding** — `withCredentials`, secret text/username-password injection
- **Git** — checkout step

## 2. Credentials to create (Manage Jenkins → Credentials → System → Global)
| ID | Type | Value |
|---|---|---|
| `dockerhub-creds` | Username with password | Docker Hub username + a Docker Hub **access token** (not your account password — create one under Docker Hub → Account Settings → Security → New Access Token) |
| `vite-firebase-api-key` | Secret text | Firebase API key baked into the client build |
| `vite-razorpay-key-id` | Secret text | Razorpay key ID baked into the client build |
| (if the GitHub repo is private) `github-creds` | Username with password / PAT | Used by the Checkout step and, optionally, by the GitHub plugin for status updates |

## 3. Jenkins job setup
1. New Item → Pipeline (or Multibranch Pipeline if you want PR/branch builds).
2. Pipeline script: "Pipeline script from SCM" → Git → your repo URL → credentials (if private) → script path `Jenkinsfile`.
3. Under **Build Triggers**, check **"GitHub hook trigger for GITScm polling"** — this is what makes the `githubPush()` trigger in the Jenkinsfile actually fire.
4. Jenkins needs the Docker CLI available on the agent that runs the job (either install Docker on the Jenkins host/agent, or use a Docker-in-Docker agent). Since Docker is already installed locally per your setup, running Jenkins directly on that host (not in a container without the socket mounted) is the simplest path — otherwise mount `/var/run/docker.sock` into the Jenkins container.

## 4. GitHub webhook
On the repo: **Settings → Webhooks → Add webhook**
- Payload URL: `http://<your-jenkins-host>:<port>/github-webhook/` (must be reachable from GitHub — use ngrok or a similar tunnel for a local Jenkins instance)
- Content type: `application/json`
- Events: "Just the push event" is enough for this pipeline
- Ensure the GitHub plugin's global config (Manage Jenkins → System → GitHub) has GitHub Servers configured if you want commit status reporting back to PRs/commits — optional for the build-and-push flow itself.

## 5. What the pipeline does
Checkout → build `backend/Dockerfile` and `client/Dockerfile` images → log in to Docker Hub → push both images tagged `${BUILD_NUMBER}` and `latest` → log out and clean up local images.

## 6. Local-Jenkins-specific note
Since Jenkins and Docker are both local (not on a public host), GitHub can't reach `localhost` directly for the webhook. Either:
- expose Jenkins via a tunnel (ngrok, Cloudflare Tunnel) and use that URL as the webhook payload URL, or
- skip the webhook for now and use **Poll SCM** (`* * * * *` or similar) as a stand-in, switching to the real webhook once Jenkins is reachable from the internet.
