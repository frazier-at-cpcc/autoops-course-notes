#!/usr/bin/env bash
# Verifies the Jenkins material in the 3.3 notes against a real Jenkins LTS:
#  - the declarative Jenkinsfile and the triggers Jenkinsfile pass the
#    declarative linter (POST /pipeline-model-converter/validate);
#  - a broken Jenkinsfile is rejected with the error shown in the notes;
#  - a multibranch job built from a local Git repo runs the Jenkinsfile for
#    branch main and for tag v1.4.0, showing BRANCH_NAME, TAG_NAME, GIT_COMMIT.
# Needs: docker, curl, jq. Pulls mirror.gcr.io/jenkins/jenkins:lts-jdk17 and
#   downloads workflow-aggregator, pipeline-model-definition, and git plugins
#   (with dependencies) into the ao-g-jenkins-plugins volume on first run.
# Uses port 127.0.0.1:18410 and container name ao-g-jenkins.
set -euo pipefail
WORK=$(mktemp -d)
JENKINS_IMAGE=mirror.gcr.io/jenkins/jenkins:lts-jdk17
cleanup() { docker rm -f ao-g-jenkins >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name ci && git config --global user.email ci@example.com
say() { printf '\n== %s\n' "$*"; }
J=http://127.0.0.1:18410

docker image inspect "$JENKINS_IMAGE" >/dev/null 2>&1 || docker pull -q "$JENKINS_IMAGE" >/dev/null
if ! docker run --rm -v ao-g-jenkins-plugins:/p --entrypoint test "$JENKINS_IMAGE" -f /p/git.jpi; then
  say "downloading plugins"
  JOPTS=(); VOLS=()
  if [ -n "${HTTPS_PROXY:-}" ]; then
    hp=${HTTPS_PROXY#*://}; hp=${hp%%/*}
    JOPTS+=("-Dhttps.proxyHost=${hp%:*}" "-Dhttps.proxyPort=${hp##*:}")
  fi
  if [ -f /root/.ccr/ca-bundle.crt ] && [ -f /etc/ssl/certs/java/cacerts ]; then
    VOLS+=(-v /etc/ssl/certs/java/cacerts:/ca/cacerts:ro)
    JOPTS+=(-Djavax.net.ssl.trustStore=/ca/cacerts -Djavax.net.ssl.trustStorePassword=changeit)
  fi
  docker run --rm -u root --name ao-g-jenkins --network host "${VOLS[@]}" \
    -v ao-g-jenkins-plugins:/plugins -e JAVA_TOOL_OPTIONS="${JOPTS[*]}" \
    --entrypoint jenkins-plugin-cli "$JENKINS_IMAGE" --plugin-download-directory /plugins \
    --plugins workflow-aggregator pipeline-model-definition git >/dev/null 2>&1
fi

say "Git repository with the Jenkinsfile, branch main and tag v1.4.0"
mkdir init.groovy.d
cat > init.groovy.d/open.groovy <<'GROOVY'
// Lab only: no login so the REST calls below need no credentials
import jenkins.model.Jenkins
def j = Jenkins.get()
j.setSecurityRealm(hudson.security.SecurityRealm.NONE)
j.setAuthorizationStrategy(new hudson.security.AuthorizationStrategy.Unsecured())
j.save()
GROOVY
git init -q -b main repo && cd repo
cat > Jenkinsfile <<'GROOVY'
pipeline {
  agent any
  options { timeout(time: 10, unit: 'MINUTES') }
  stages {
    stage('Build') {
      steps {
        sh 'mkdir -p dist'
        sh 'echo "vlan 10" > dist/core-sw1.cfg'
      }
    }
    stage('Test') {
      steps {
        sh 'grep -q "vlan 10" dist/core-sw1.cfg'
      }
    }
    stage('Deploy') {
      when { branch 'main' }
      steps {
        sh 'echo "deploy $GIT_COMMIT"'
      }
    }
    stage('Release') {
      when { buildingTag() }
      steps {
        sh 'echo "release $TAG_NAME"'
      }
    }
  }
  post {
    failure { echo 'notify #netops' }
  }
}
GROOVY
awk 'length > 52 { print "line too long: " $0; exit 1 }' Jenkinsfile
git add . && git commit -qm "ci: add Jenkinsfile"
git tag -a v1.4.0 -m "Release 1.4.0"
SHA=$(git rev-parse HEAD)
cd ..
cat > triggers.Jenkinsfile <<'GROOVY'
pipeline {
  agent any
  triggers { cron('H 2 * * *') }
  parameters {
    choice(name: 'TARGET',
           choices: ['staging', 'production'])
  }
  stages {
    stage('Deploy') {
      when { branch 'main' }
      input { message 'Deploy to production?' }
      steps { echo "deploy to ${params.TARGET}" }
    }
  }
}
GROOVY
awk 'length > 52 { print "line too long: " $0; exit 1 }' triggers.Jenkinsfile
# Broken copy: the steps block was left out of the Test stage
sed '/stage(.Test.)/,/^    }$/{/steps {/d;/^      }$/d}' repo/Jenkinsfile > broken.Jenkinsfile
chmod -R a+rX "$WORK"
chown -R 1000:1000 repo   # the jenkins user (uid 1000) reads the repo

say "start Jenkins"
docker run -d --name ao-g-jenkins -p 127.0.0.1:18410:8080 \
  -v ao-g-jenkins-plugins:/usr/share/jenkins/ref/plugins:ro \
  -v "$WORK/init.groovy.d":/usr/share/jenkins/ref/init.groovy.d:ro \
  -v "$WORK/repo":/repo:ro \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.model.UpdateCenter.never=true -Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true" \
  "$JENKINS_IMAGE" >/dev/null
for _ in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' $J/pipeline-model-converter/validate)" = 405 ] && break
  sleep 2
done
curl -s $J/api/json >/dev/null
docker exec ao-g-jenkins sh -c 'java -jar /usr/share/jenkins/jenkins.war --version'

say "declarative linter"
cp repo/Jenkinsfile Jenkinsfile
curl -s -X POST -F "jenkinsfile=<Jenkinsfile" \
    $J/pipeline-model-converter/validate | tee lint-good.txt
grep -qx 'Jenkinsfile successfully validated.' lint-good.txt
curl -s -X POST -F "jenkinsfile=<triggers.Jenkinsfile" \
  $J/pipeline-model-converter/validate | tee lint-triggers.txt
grep -qx 'Jenkinsfile successfully validated.' lint-triggers.txt
cp broken.Jenkinsfile Jenkinsfile
curl -s -X POST -F "jenkinsfile=<Jenkinsfile" \
    $J/pipeline-model-converter/validate | tee lint-bad.txt
grep -qx 'Errors encountered validating Jenkinsfile:' lint-bad.txt
grep -q 'Unknown stage section "sh"' lint-bad.txt
grep -q 'Expected one of "steps", "stages", or "parallel" for stage "Test"' lint-bad.txt

say "multibranch job: build main and tag v1.4.0"
CJ="$WORK/cookies"
CRUMB=$(curl -s -c "$CJ" $J/crumbIssuer/api/json | jq -r '.crumbRequestField + ":" + .crumb')
jpost() { curl -s -b "$CJ" -H "$CRUMB" -X POST -o /dev/null -w '%{http_code}' "$@"; }
cat > multibranch.xml <<'XML'
<org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject>
  <sources class="jenkins.branch.MultiBranchProject$BranchSourceList">
    <data>
      <jenkins.branch.BranchSource>
        <source class="jenkins.plugins.git.GitSCMSource">
          <id>netops</id>
          <remote>file:///repo</remote>
          <traits>
            <jenkins.plugins.git.traits.BranchDiscoveryTrait/>
            <jenkins.plugins.git.traits.TagDiscoveryTrait/>
          </traits>
        </source>
      </jenkins.branch.BranchSource>
    </data>
  </sources>
  <factory class="org.jenkinsci.plugins.workflow.multibranch.WorkflowBranchProjectFactory">
    <scriptPath>Jenkinsfile</scriptPath>
  </factory>
</org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject>
XML
[ "$(jpost -H 'Content-Type: application/xml' --data-binary @multibranch.xml "$J/createItem?name=netops")" = 200 ]
jpost $J/job/netops/build >/dev/null
done_build() { curl -s "$J/job/netops/job/$1/lastBuild/api/json" | jq -e '.building == false' >/dev/null 2>&1; }
for _ in $(seq 1 120); do done_build main && break; sleep 2; done
done_build main
curl -s $J/job/netops/indexing/consoleText | grep -E 'Checking tag|build triggered' | tee indexing.txt
grep -q 'No automatic build triggered for v1.4.0' indexing.txt
[ "$(jpost $J/job/netops/job/v1.4.0/build)" = 201 ]
for _ in $(seq 1 120); do done_build v1.4.0 && break; sleep 2; done
done_build v1.4.0
for b in main v1.4.0; do
  echo "--- netops/$b"
  curl -s "$J/job/netops/job/$b/lastBuild/consoleText" \
    | grep -E '^\[Pipeline\] \{ \(|^\+ |^deploy|^release|^Stage "|^Checking out|^Finished' | tee "build-$b.txt"
done
grep -q "Checking out Revision $SHA (main)" build-main.txt
grep -qx "deploy $SHA" build-main.txt
grep -qx 'Stage "Release" skipped due to when conditional' build-main.txt
grep -qx 'Finished: SUCCESS' build-main.txt
grep -q "Checking out Revision $SHA (v1.4.0)" build-v1.4.0.txt
grep -qx 'release v1.4.0' build-v1.4.0.txt
grep -qx 'Stage "Deploy" skipped due to when conditional' build-v1.4.0.txt
grep -qx 'Finished: SUCCESS' build-v1.4.0.txt

say "environment of the tag build (script console)"
cat > env.groovy <<'GROOVY'
def run = Jenkins.get().getItemByFullName('netops/v1.4.0').lastBuild
def env = run.getEnvironment(TaskListener.NULL)
['BRANCH_NAME', 'TAG_NAME', 'GIT_COMMIT'].each { println "${it}=${env[it]}" }
GROOVY
curl -s -b "$CJ" -H "$CRUMB" --data-urlencode "script@env.groovy" $J/scriptText | tee env.txt
grep -qx 'BRANCH_NAME=v1.4.0' env.txt
grep -qx 'TAG_NAME=v1.4.0' env.txt

echo
echo "ALL 3.3 JENKINS CHECKS PASSED"
