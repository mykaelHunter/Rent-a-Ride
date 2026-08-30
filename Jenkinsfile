// Rent-a-Ride — CI pipeline
// Trigger: GitHub webhook (push to main) -> builds backend + client images
// and pushes both to Docker Hub, tagged with the build number and `latest`.

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    triggers {
        // Fired by the GitHub webhook (needs the GitHub plugin + a webhook
        // configured on the repo pointing at http://<jenkins-host>/github-webhook/)
        githubPush()
    }

    environment {
        DOCKERHUB_CREDENTIALS = credentials('dockerhub-creds')   // Username + Password/Token cred
        DOCKERHUB_NAMESPACE   = 'mykaelhunter'                    // <- change to your Docker Hub username/org
        BACKEND_IMAGE         = "${DOCKERHUB_NAMESPACE}/rent-a-ride-backend"
        CLIENT_IMAGE          = "${DOCKERHUB_NAMESPACE}/rent-a-ride-client"
        IMAGE_TAG             = "${env.BUILD_NUMBER}"
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build Backend Image') {
            steps {
                sh """
                    docker build \
                        -f backend/Dockerfile \
                        -t ${BACKEND_IMAGE}:${IMAGE_TAG} \
                        -t ${BACKEND_IMAGE}:latest \
                        .
                """
            }
        }

        stage('Build Client Image') {
            steps {
                // VITE_* build args baked into the static bundle at build time.
                // Store real values as Jenkins Secret Text credentials rather
                // than hardcoding them here.
                withCredentials([
                    string(credentialsId: 'vite-firebase-api-key', variable: 'VITE_FIREBASE_API_KEY'),
                    string(credentialsId: 'vite-razorpay-key-id',  variable: 'VITE_RAZORPAY_KEY_ID')
                ]) {
                    sh """
                        docker build \
                            -f client/Dockerfile \
                            --build-arg VITE_PRODUCTION_BACKEND_URL=https://api.rent-a-ride.example.com \
                            --build-arg VITE_FIREBASE_API_KEY=${VITE_FIREBASE_API_KEY} \
                            --build-arg VITE_RAZORPAY_KEY_ID=${VITE_RAZORPAY_KEY_ID} \
                            -t ${CLIENT_IMAGE}:${IMAGE_TAG} \
                            -t ${CLIENT_IMAGE}:latest \
                            ./client
                    """
                }
            }
        }

        stage('Login to Docker Hub') {
            steps {
                sh 'echo $DOCKERHUB_CREDENTIALS_PSW | docker login -u $DOCKERHUB_CREDENTIALS_USR --password-stdin'
            }
        }

        stage('Push Images') {
            steps {
                sh """
                    docker push ${BACKEND_IMAGE}:${IMAGE_TAG}
                    docker push ${BACKEND_IMAGE}:latest
                    docker push ${CLIENT_IMAGE}:${IMAGE_TAG}
                    docker push ${CLIENT_IMAGE}:latest
                """
            }
        }

        stage('Pull Images from Docker Hub') {
            steps {
                // Drop the just-built local tags first so the following pull
                // is a real round-trip to Docker Hub, not a local no-op —
                // this is what actually gets deployed, matching what any
                // other machine pulling these tags would get. Pulls :latest
                // specifically (not the build-number tag) so this stage and
                // the Deploy stage below actually use the tag this pipeline
                // just pushed - ArgoCD Image Updater elsewhere in this repo
                // also tracks these images by :latest's digest, so this
                // keeps the Jenkins/docker-compose deploy path and the
                // Argo CD/k8s path pointed at the same tag.
                sh """
                    docker rmi -f ${BACKEND_IMAGE}:${IMAGE_TAG} ${BACKEND_IMAGE}:latest \
                                  ${CLIENT_IMAGE}:${IMAGE_TAG} ${CLIENT_IMAGE}:latest || true
                    docker pull ${BACKEND_IMAGE}:latest
                    docker pull ${CLIENT_IMAGE}:latest
                """
            }
        }

        stage('Write backend/.env') {
            steps {
                // backend/.env is gitignored (it holds real secrets), so a
                // fresh checkout never has it. Pull the real file from a
                // Jenkins Secret File credential instead of committing it.
                withCredentials([file(credentialsId: 'backend-env-file', variable: 'BACKEND_ENV_FILE')]) {
                    sh 'cp "$BACKEND_ENV_FILE" backend/.env'
                }
            }
        }

        stage('Deploy via Docker Compose') {
            steps {
                // docker-compose.yml's backend/client services read these
                // env vars into their `image:` field (falling back to
                // :latest / the default names for a plain local `docker
                // compose up` with nothing set). No --build flag here —
                // compose uses the images just pulled above.
                sh """
                    BACKEND_IMAGE=${BACKEND_IMAGE} \
                    CLIENT_IMAGE=${CLIENT_IMAGE} \
                    IMAGE_TAG=latest \
                    docker compose -f docker-compose.yml up -d
                """
            }
        }

        stage('Remove Local Images') {
            steps {
                // Frees disk space on the Jenkins host. Note: since the
                // containers just started above are running from these
                // exact images, Docker keeps the underlying layers alive
                // until those containers are stopped/removed — this
                // removes the dangling tag references now, and the actual
                // layer space is reclaimed once the containers themselves
                // are torn down (e.g. `docker compose down` + `docker
                // image prune`).
                sh """
                    docker rmi -f ${BACKEND_IMAGE}:${IMAGE_TAG} ${BACKEND_IMAGE}:latest \
                                  ${CLIENT_IMAGE}:${IMAGE_TAG} ${CLIENT_IMAGE}:latest || true
                """
            }
        }
    }

    post {
        always {
            sh 'docker logout || true'
            // backend/.env was written to the workspace from a credential
            // above — remove it so the plaintext secret doesn't linger on
            // disk between builds (the workspace itself isn't wiped by
            // default between runs).
            sh 'rm -f backend/.env || true'
        }
        success {
            echo "Built and pushed ${BACKEND_IMAGE}:${IMAGE_TAG} / :latest and ${CLIENT_IMAGE}:${IMAGE_TAG} / :latest; deployed :latest via docker compose."
        }
        failure {
            echo "Build failed — check which stage stopped the pipeline above."
        }
    }
}
