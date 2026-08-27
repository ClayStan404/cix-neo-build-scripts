pipeline {
    agent any

    options {
        timestamps()
    }

    parameters {
        text(name: 'CHANGED_PROJECTS', defaultValue: '', description: 'One manifest project or workspace path per line')
        choice(name: 'DEBIAN_BACKEND', choices: ['sbuild', 'local'], description: 'Debian package build backend')
        booleanParam(name: 'RESUME', defaultValue: true, description: 'Reuse verified target artifacts')
        string(name: 'EXECUTOR_JOBS', defaultValue: '1', description: 'Independent build targets run concurrently')
    }

    stages {
        stage('Host and mapping checks') {
            steps {
                sh 'build-scripts/setup-host --check'
                sh 'build-scripts/ci/plan.py --check'
            }
        }

        stage('Build affected targets') {
            steps {
                sh '''
                    set -eu
                    resume_option=
                    if [ "${RESUME}" = true ]; then
                        resume_option=--resume
                    fi
                    printf '%s\n' "${CHANGED_PROJECTS}" |
                        build-scripts/ci/execute.py \
                            --backend "${DEBIAN_BACKEND}" \
                            --jobs "${EXECUTOR_JOBS}" \
                            ${resume_option} \
                            --apt-repo "output/apt-repositories/build-${BUILD_NUMBER}"
                '''
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'output/build-reports/**,output/jenkins-reports/**,output/apt-repositories/**', allowEmptyArchive: true, fingerprint: true
        }
    }
}
