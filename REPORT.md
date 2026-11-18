# CSC418 DevOps for Cloud Computing – Lab Midterm Report

| Item | Value |
|---|---|
| Student Reg No | FA23-BCT-031 |
| GitHub repository | https://github.com/nimrahumar516/devops-labmidterm-FA23-BCT-031 |
| Jenkins job | `MIDTERM-FA23-BCT-031` – http://3.25.65.210:8080/job/MIDTERM-FA23-BCT-031/ |
| EC2 /metrics URL | http://3.25.65.210:8000/metrics |
| Sender email (Jenkins From) | nimrahumar516@gmail.com |
| Notification recipient | qasimalik@gmail.com |

## Architecture

```
GitHub push (data/code)
   │  webhook  POST http://3.25.65.210:8080/github-webhook/
   ▼
Jenkins on AWS EC2 (Ubuntu 24.04, c7i-flex.large, ap-southeast-2)
   1. Fetch latest data      (checkout scm → dataset/train.csv)
   2. Build trainer image    (Dockerfile target "trainer")
   3. Train model            (python train.py → artifacts/metrics.json, model.joblib)
   4. Run tests              (pytest tests/)
   5. Build app image        (Dockerfile target "runtime" with new model)
   6. Deploy on EC2          (docker run -p 8000:8000, smoke test /metrics)
   7. Post-build email       (Gmail SMTP → qasimalik@gmail.com, subject contains FA23-BCT-031)
   ▼
FastAPI container on EC2 :8000  →  GET /metrics, POST /predict
```

## Step 1 – Individual dataset and GitHub repository

1. Cloned the starter code from https://github.com/malik-qasim/devops-labmidterm-FA26.
2. Copied my assigned config `configs/FA23-BCT-031.json` to `config.json`
   (scenario `cloud_host`, seed 24383, variant `outliers`).
3. Generated the dataset: `python generate_dataset.py` → `dataset/train.csv` (300 rows).
4. Created the public repository and pushed `config.json`, `dataset/train.csv` and the code.
5. Added `qasimalik@gmail.com` as a collaborator (Settings → Collaborators).

> Screenshot 1: repository file list
> Screenshot 2: collaborator invitation

## Step 2 – Jenkinsfile and Dockerfile

The Dockerfile is multi-stage so that training, tests and serving use identical library versions
(the pickled scikit-learn model is always loaded by the same version that created it).

**Dockerfile**

```dockerfile
# Multi-stage image so training, tests and serving all use identical library versions.
# Stage "base": runtime dependencies only (cached between builds).
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

# Stage "trainer": base + test tooling. Jenkins runs train.py and pytest in this image.
FROM base AS trainer
RUN pip install "pytest>=8,<10" "httpx>=0.27,<1"

# Stage "runtime": the FastAPI service with the freshly trained model baked in.
FROM base AS runtime
COPY app.py .
COPY artifacts/ artifacts/
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Jenkinsfile (pipeline script)**

```groovy
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
```

## Step 3 – AWS EC2 and Jenkins

1. Launched EC2 instance `MIDTERM-FA23-BCT-031` (Ubuntu 24.04, c7i-flex.large, 20 GB gp3) with a
   security group allowing TCP 22, 8080 (Jenkins) and 8000 (FastAPI).
2. User data ran `ec2-setup.sh`: 2 GB swap, Docker, OpenJDK 21, Jenkins LTS as a systemd service,
   and added the `jenkins` user to the `docker` group.
3. Unlocked Jenkins, installed suggested plugins, created the admin user.
4. Created Pipeline job **MIDTERM-FA23-BCT-031** → *Pipeline script from SCM* (Git, branch `main`,
   script path `Jenkinsfile`) with **GitHub hook trigger for GITScm polling** enabled.

> Screenshot 3: EC2 instance running
> Screenshot 4: Jenkins job configuration

## Step 4 – GitHub webhook

Repository → Settings → Webhooks → Add webhook:
- Payload URL: `http://3.25.65.210:8080/github-webhook/`
- Content type: `application/json`, event: *Just the push event*

> Screenshot 5: webhook with green tick (delivery 200)
> Screenshot 6: build "Started by GitHub push"

## Step 5 – FastAPI on port 8000

- `GET http://3.25.65.210:8000/metrics` → `student_id, accuracy, training_rows, model_version, git_sha`
- `POST http://3.25.65.210:8000/predict` with `{"records":[{...features...}]}`

> Screenshot 7: /metrics response
> Screenshot 8: /predict response

## Step 6 – Email notification

Manage Jenkins → System:
- System Admin e-mail address: `nimrahumar516@gmail.com`
- E-mail Notification: SMTP `smtp.gmail.com`, port 465, SSL, SMTP authentication with a Gmail App Password.

The `post { always { mail ... } }` block sends the result to `qasimalik@gmail.com` with subject
`FA23-BCT-031 - MIDTERM-FA23-BCT-031 #<build> - <RESULT>`.

> Screenshot 9: Jenkins email configuration (password hidden)
> Screenshot 10: received email

## Step 7 – End-to-end verification

A test push to `dataset/train.csv` triggered the job automatically through the webhook; the pipeline
retrained the model, passed the tests, redeployed the container and `/metrics` showed the new
`training_rows`, `model_version` and `git_sha`; the email arrived within minutes.

> Screenshot 11: Stage View with all stages green
