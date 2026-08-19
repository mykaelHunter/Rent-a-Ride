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
    }

    post {
        always {
            sh 'docker logout || true'
            sh """
                docker image rm ${BACKEND_IMAGE}:${IMAGE_TAG} ${BACKEND_IMAGE}:latest \
                                ${CLIENT_IMAGE}:${IMAGE_TAG} ${CLIENT_IMAGE}:latest || true
            """
        }
        success {
            echo "Pushed ${BACKEND_IMAGE}:${IMAGE_TAG} and ${CLIENT_IMAGE}:${IMAGE_TAG} to Docker Hub."
        }
        failure {
            echo "Build failed — images were not pushed."
        }
    }
}
