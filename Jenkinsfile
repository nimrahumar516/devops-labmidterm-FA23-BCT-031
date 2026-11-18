// CSC418 Lab Midterm - automated ML retraining pipeline.
// Triggered by a GitHub push webhook: fetch latest data -> train -> test -> build image -> redeploy on EC2 -> email.
pipeline {
    agent any

    triggers {
        githubPush()
    }

    options {
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 15, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        STUDENT_ID    = 'FA23-BCT-031'
        SENDER_EMAIL  = 'nimrahumar516@gmail.com'
        NOTIFY_EMAIL  = 'qasimalik@gmail.com'
        TRAINER_IMAGE = "midterm-trainer"
        APP_IMAGE     = "midterm-app"
        CONTAINER     = "midterm-app"
        APP_PORT      = '8000'
    }

    stages {
        stage('Fetch latest data') {
            steps {
                checkout scm
                sh '''
                    echo "Commit: ${GIT_COMMIT}"
                    git log -1 --oneline
                    echo "Training rows (incl. header): $(wc -l < dataset/train.csv)"
                '''
            }
        }

        stage('Build trainer image') {
            steps {
                sh 'docker build --target trainer -t ${TRAINER_IMAGE}:latest .'
            }
        }

        stage('Train model') {
            steps {
                sh '''
                    rm -rf artifacts
                    docker run --rm -u "$(id -u):$(id -g)" \
                        -e GIT_COMMIT="${GIT_COMMIT}" \
                        -v "${WORKSPACE}":/work -w /work \
                        ${TRAINER_IMAGE}:latest python train.py
                    cat artifacts/metrics.json
                '''
            }
        }

        stage('Run tests') {
            steps {
                sh '''
                    docker run --rm -u "$(id -u):$(id -g)" \
                        -v "${WORKSPACE}":/work -w /work \
                        ${TRAINER_IMAGE}:latest python -m pytest -q -p no:cacheprovider tests
                '''
            }
        }

        stage('Build app image') {
            steps {
                sh '''
                    docker build --target runtime \
                        -t ${APP_IMAGE}:${BUILD_NUMBER} -t ${APP_IMAGE}:latest .
                '''
            }
        }

        stage('Deploy on EC2') {
            steps {
                sh '''
                    docker rm -f ${CONTAINER} || true
                    docker run -d --name ${CONTAINER} --restart unless-stopped \
                        -p ${APP_PORT}:8000 ${APP_IMAGE}:${BUILD_NUMBER}

                    # Smoke test: wait for the new container to serve the new model.
                    for i in $(seq 1 30); do
                        if curl -fs http://localhost:${APP_PORT}/metrics > live_metrics.json \
                           && grep -q "${GIT_COMMIT}" live_metrics.json; then
                            echo "Deployed:"; cat live_metrics.json; exit 0
                        fi
                        sleep 2
                    done
                    echo "Deployment did not become healthy"; docker logs ${CONTAINER}; exit 1
                '''
                sh 'docker image prune -f || true'
            }
        }
    }

    post {
        always {
            script {
                def metrics = fileExists('artifacts/metrics.json') ? readFile('artifacts/metrics.json') : 'metrics not produced'
                def status = currentBuild.currentResult
                try {
                mail(
                    to: env.NOTIFY_EMAIL,
                    from: env.SENDER_EMAIL,
                    subject: "${env.STUDENT_ID} - ${env.JOB_NAME} #${env.BUILD_NUMBER} - ${status}",
                    body: """Student Reg No: ${env.STUDENT_ID}
Job: ${env.JOB_NAME} #${env.BUILD_NUMBER}
Result: ${status}
Commit: ${env.GIT_COMMIT}
Build URL: ${env.BUILD_URL}

Model metrics:
${metrics}
"""
                )
                echo "Notification email sent to ${env.NOTIFY_EMAIL}"
                } catch (err) {
                    echo "WARNING: email could not be sent: ${err}"
                }
            }
        }
    }
}
