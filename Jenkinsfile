// VLE-9 - Secure DevSecOps pipeline for the MedSecure healthcare app (Step 10).
//
// Shift-left order: the cheapest checks run first, and each stage is a
// security GATE. A failure stops the pipeline, so a vulnerable build never
// reaches Kubernetes.
//
//   Checkout -> Secrets Scan (Gitleaks) -> Unit Tests -> SCA + IaC Scan
//   -> SAST + Quality Gate (SonarQube) -> Build Image -> Container Scan (Trivy)
//   -> Deploy (least-privilege RBAC) -> DAST (OWASP ZAP, auto-rollback on fail)
//
// Jenkins prerequisites (scripts/ec2/06-configure-jenkins.sh sets them up):
//   * SonarQube server named "sonarqube" (Manage Jenkins > System)
//   * Credentials: "jenkins-deployer-kubeconfig" (Secret file)
//                  "medsecure-app-secrets"       (Secret file, env format)
//   * The jenkins user is in the "docker" group; trivy + kubectl installed.

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '15', artifactNumToKeepStr: '10'))
    timeout(time: 45, unit: 'MINUTES')
  }

  triggers {
    pollSCM('H/2 * * * *') // EC2 security group blocks inbound webhooks, so poll GitHub
  }

  parameters {
    string(name: 'BASE_IMAGE', defaultValue: '',
      description: 'DEMO: override the Docker base image. Try node:18-alpine (end-of-life) to watch the Trivy gate block the build.')
    booleanParam(name: 'RUN_DAST', defaultValue: true,
      description: 'Run the OWASP ZAP baseline scan against the deployed app')
  }

  environment {
    APP_NAME            = 'medsecure-patient-api'
    NODE_IMAGE          = 'node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5'
    GITLEAKS_IMAGE      = 'zricethezav/gitleaks:v8.30.1'
    SONAR_SCANNER_IMAGE = 'sonarsource/sonar-scanner-cli:12.4.0.4321_8.4.0'
    ZAP_IMAGE           = 'ghcr.io/zaproxy/zaproxy:2.17.0'
    TRIVY_SEVERITY      = 'HIGH,CRITICAL'
    MINIKUBE_PROFILE    = 'minikube'
  }

  stages {
    stage('Checkout') {
      steps {
        script {
          env.GIT_SHORT = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
          env.IMAGE = "${env.APP_NAME}:${env.BUILD_NUMBER}-${env.GIT_SHORT}"
          currentBuild.description = env.IMAGE
        }
        sh 'rm -rf reports && mkdir -p reports && chmod +x scripts/*.sh scripts/ci/*.sh'
        echo "Building ${env.IMAGE}"
      }
    }

    stage('Secrets Scan (Gitleaks)') {
      steps { sh 'scripts/ci/gitleaks.sh' }
    }

    stage('Unit Tests') {
      steps { sh 'scripts/ci/unit-tests.sh' }
      post { always { junit allowEmptyResults: true, testResults: 'reports/junit.xml' } }
    }

    stage('SCA + IaC Scan') {
      steps { sh 'scripts/ci/sca-scan.sh' }
    }

    stage('SAST + Quality Gate (SonarQube)') {
      steps {
        withSonarQubeEnv('sonarqube') {
          sh 'scripts/ci/sonar-scan.sh'
        }
      }
    }

    stage('Build Image') {
      steps { sh 'scripts/ci/build-image.sh "$IMAGE" "${BASE_IMAGE:-}"' }
    }

    stage('Container Scan (Trivy)') {
      steps { sh 'scripts/ci/trivy-image.sh "$IMAGE"' }
    }

    stage('Deploy to Kubernetes') {
      steps {
        withCredentials([
          file(credentialsId: 'jenkins-deployer-kubeconfig', variable: 'KUBECONFIG'),
          file(credentialsId: 'medsecure-app-secrets', variable: 'APP_SECRETS_FILE'),
        ]) {
          sh 'scripts/ci/load-image.sh "$IMAGE"'
          sh 'scripts/deploy.sh "$IMAGE" "Jenkins build #$BUILD_NUMBER ($GIT_SHORT)"'
        }
      }
    }

    stage('DAST (OWASP ZAP)') {
      when { expression { params.RUN_DAST != false } }
      steps { sh 'scripts/ci/zap-baseline.sh' }
      post {
        failure {
          withCredentials([file(credentialsId: 'jenkins-deployer-kubeconfig', variable: 'KUBECONFIG')]) {
            sh 'scripts/rollback.sh "DAST failed for $IMAGE"'
          }
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
      publishHTML(target: [
        reportName: 'OWASP ZAP Report', reportDir: 'reports/zap', reportFiles: 'zap-report.html',
        keepAll: true, alwaysLinkToLastBuild: true, allowMissing: true,
      ])
    }
    success {
      echo "SECURE PIPELINE PASSED: ${env.IMAGE} is running in namespace healthcare"
    }
    failure {
      echo 'PIPELINE BLOCKED: a security gate failed. Open the failed stage log and the archived reports/.'
    }
    cleanup {
      sh 'docker image prune -f >/dev/null 2>&1 || true'
    }
  }
}
