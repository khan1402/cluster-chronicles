// Jenkinsfile - cluster-chronicles CI/CD pipeline, running INSIDE Kubernetes.
//
// Every build runs in its own pod (ci/build-agent-pod.yaml), deleted afterwards.
// Jenkins checks Gitea every minute. For every new commit:
//   1. Version      - short commit ID = image tag; record the live version (for rollback)
//   2. Code checks  - Ruff, Bandit, pytest                        (container: python)
//   3. Build & push - Kaniko builds both images, pushes to Docker Hub  (kaniko)
//   4. Image scan   - Trivy: stop on a CRITICAL fixable vulnerability  (trivy)
//   5. Deploy       - rolling update of backend, then frontend    (tools: kubectl)
//   6. Smoke test   - through the Ingress: new version on 2+ frontend pods
//   7. Load test    - k6: fail on errors or slow pages             (k6)
//
// A failure in 1-4 blocks the deploy: users keep the version they have.
// A failure in 5-7 deploys the previous version again automatically.
// Every result is posted to Slack.

pipeline {
    agent {
        kubernetes {
            yamlFile 'ci/build-agent-pod.yaml'
        }
    }

    options {
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds()                       // never two deploys at once
        buildDiscarder(logRotator(numToKeepStr: '20'))  // keep the last 20 builds
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        DOCKERHUB_USER  = 'zeek14'
        IMAGE_PREFIX    = 'chronicles'
        APP_NAMESPACE   = 'app'
        // The Ingress controller's Service: the same path users take (Ingress -> frontend -> backend)
        LB_URL          = 'http://ingress-nginx-controller.ingress-nginx.svc.cluster.local/'
        PUBLIC_URL      = 'http://192.168.0.122/'
        KUBECTL_VERSION = 'v1.37.0'                     // same version as the cluster
    }

    stages {
        stage('Version') {
            steps {
                // jnlp container: does the checkout, has git
                script {
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG}"
                }
                sh 'git log -1 --format="Commit %h by %an: %s"'

                container('tools') {
                    // Small tool kit for deploy, smoke test and Slack.
                    sh '''
                        apk add --no-cache --quiet bash curl git python3
                        curl -fsSLo /usr/local/bin/kubectl \
                          "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
                        chmod +x /usr/local/bin/kubectl
                        git config --global --add safe.directory "$WORKSPACE"
                        kubectl version --client
                    '''
                    script {
                        // What users run right now = what we roll back to if this deploy fails.
                        env.PREVIOUS_TAG = sh(script: 'bash ci/deploy.sh current', returnStdout: true).trim()
                    }
                }
                echo "Live version before this build: ${env.PREVIOUS_TAG ?: 'none'}"
            }
        }

        stage('Code checks') {
            steps {
                container('python') {
                    sh 'rm -rf reports'
                    sh 'bash ci/code-checks.sh backend'
                    sh 'bash ci/code-checks.sh frontend'
                }
            }
        }

        stage('Build & push (Kaniko)') {
            steps {
                container('kaniko') {
                    // No Docker daemon: Kaniko reads the Dockerfile, builds the image
                    // in user space and pushes it straight to Docker Hub, using the
                    // login file mounted from the dockerhub-push Secret.
                    // --cleanup: reset Kaniko's filesystem between the two builds.
                    sh '''
                        for component in backend frontend; do
                          /kaniko/executor \
                            --context "$WORKSPACE/app/$component" \
                            --dockerfile "$WORKSPACE/app/$component/Dockerfile" \
                            --build-arg APP_VERSION="$IMAGE_TAG" \
                            --destination "$DOCKERHUB_USER/$IMAGE_PREFIX-$component:$IMAGE_TAG" \
                            --digest-file "$WORKSPACE/$component.digest" \
                            --push-retry 3 \
                            --cleanup
                        done
                    '''
                }
                container('tools') {
                    // The build artifact: which commit produced which exact images.
                    sh '''
                        {
                          echo "version:  $IMAGE_TAG"
                          echo "commit:   $(git rev-parse HEAD)"
                          echo "built:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                          echo "jenkins:  build #$BUILD_NUMBER"
                          for component in backend frontend; do
                            echo "$component: $DOCKERHUB_USER/$IMAGE_PREFIX-$component@$(cat "$component.digest")"
                          done
                        } > build-info.txt
                        cat build-info.txt
                    '''
                }
                archiveArtifacts artifacts: 'build-info.txt', fingerprint: true
            }
        }

        stage('Image scan (Trivy)') {
            steps {
                container('trivy') {
                    // Scans the image straight from Docker Hub (no Docker daemon needed).
                    // Report HIGH + CRITICAL, but only FAIL on CRITICAL with a fix available.
                    // The image is never deployed if this stage fails.
                    sh '''
                        for component in backend frontend; do
                          image="$DOCKERHUB_USER/$IMAGE_PREFIX-$component:$IMAGE_TAG"
                          echo "=== Trivy: $image - HIGH + CRITICAL (report only) ==="
                          trivy image --quiet --scanners vuln --ignore-unfixed \
                            --severity HIGH,CRITICAL --exit-code 0 "$image"
                          echo "=== Trivy: $image - gate: fail on CRITICAL with a fix available ==="
                          trivy image --quiet --scanners vuln --ignore-unfixed \
                            --severity CRITICAL --exit-code 1 "$image"
                        done
                    '''
                }
            }
        }

        stage('Deploy') {
            steps {
                script {
                    // From here on, a failure means the cluster may run a broken
                    // version -> the post section rolls back.
                    env.DEPLOY_STARTED = 'true'
                    deployVersion(env.IMAGE_TAG)
                }
            }
        }

        stage('Smoke test') {
            steps {
                container('tools') {
                    sh 'bash scripts/smoke-test.sh "$LB_URL" "$IMAGE_TAG"'
                }
            }
        }

        stage('Load test') {
            steps {
                container('k6') {
                    sh 'k6 run --quiet -e TARGET_URL="$LB_URL" -e VERSION="$IMAGE_TAG" ci/load-test.js'
                }
            }
        }
    }

    post {
        always {
            // Unit test results -> "Tests" tab and trend graph in Jenkins.
            junit testResults: 'reports/*.xml', allowEmptyResults: true
        }
        success {
            notifySlack('SUCCESS', "Version ${env.IMAGE_TAG} is live on ${env.PUBLIC_URL}")
        }
        failure {
            script {
                if (env.DEPLOY_STARTED != 'true') {
                    // Failed in a check, build or scan: the cluster was never touched.
                    notifySlack('BLOCKED', "Version ${env.IMAGE_TAG} failed before deploy. " +
                                      "Users still see ${env.PREVIOUS_TAG ?: 'the previous version'}.")
                } else if (!env.PREVIOUS_TAG || env.PREVIOUS_TAG == env.IMAGE_TAG) {
                    notifySlack('ROLLBACK_FAILED', "Version ${env.IMAGE_TAG} failed after deploy and " +
                                              "there is no different previous version to roll back to.")
                } else {
                    echo "=== ROLLBACK: deploying the previous version ${env.PREVIOUS_TAG} ==="
                    try {
                        deployVersion(env.PREVIOUS_TAG)
                        container('tools') {
                            sh 'bash scripts/smoke-test.sh "$LB_URL" "$PREVIOUS_TAG"'
                        }
                        notifySlack('ROLLED_BACK', "Version ${env.IMAGE_TAG} failed after deploy. " +
                                              "Rolled back to ${env.PREVIOUS_TAG} - users see a working site.")
                    } catch (err) {
                        notifySlack('ROLLBACK_FAILED', "Version ${env.IMAGE_TAG} failed AND the rollback to " +
                                                  "${env.PREVIOUS_TAG} failed: ${err.getMessage()}")
                    }
                }
            }
        }
    }
}

// --- Helpers ---------------------------------------------------------------

// Deploy one version with the same script as every deploy (rolling update).
def deployVersion(String tag) {
    container('tools') {
        sh "bash ci/deploy.sh ${tag}"
    }
}

// Post the result to Slack. A missing credential or a Slack outage never fails the build.
def notifySlack(String status, String text) {
    try {
        container('tools') {
            withCredentials([string(credentialsId: 'slack-webhook', variable: 'SLACK_WEBHOOK_URL')]) {
                withEnv(["NOTIFY_STATUS=${status}", "NOTIFY_TEXT=${text}"]) {
                    sh 'bash ci/notify.sh'
                }
            }
        }
    } catch (err) {
        echo "Slack notification skipped: ${err.getMessage()}"
    }
}