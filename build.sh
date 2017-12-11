#!/usr/bin/env bash

# "Bash strict mode" settings - http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -e          # exit on error (like a normal programming langauge)
set -u          # fail when undefined variables are used
set -o pipefail # prevent errors in a pipeline from being masked

BRANCH=image-unstable
PENDING_PRS=${PWD}/pending-prs-unstable.json
BASEDIR=${PWD}/manageiq-unstable
CORE_REPO=manageiq
GITHUB_ORG=container-mgmt
PRS_JSON=$(jq -Mc . "${PENDING_PRS}")

# Even when push is done with deploy keys, we need username and password
# or access token to avoid API rate limits
set +u # temporarily allow undefined variables
if [ -z "${GIT_USER}" ]; then
    read -p "GitHub username: " -r GIT_USER
fi
if [ -z "${GIT_PASSWORD}" ]; then
    read -p "GitHub password (or token) for ${GIT_USER}:" -sr GIT_PASSWORD
fi
set -u # disallow undefined variables again

mkdir "${BASEDIR}"
cd "${BASEDIR}"

# Read repo list from the pending PRs json
repos=$(jq "keys[]" -r "${PENDING_PRS}")

for repo in ${repos}; do
    echo -e "\n\n\n** DOING REPO ${repo}**\n----------------------------------------------\n"
    git clone "https://github.com/ManageIQ/${repo}" --depth 1
    pushd "${repo}"
    git remote add "${GITHUB_ORG}" "git@github.com:${GITHUB_ORG}/${repo}"

    #weird bash hack
    string_escaped_repo=\"${repo}\"

    git checkout -b image-unstable
    if [ "${repo}" == "${CORE_REPO}" ]; then
        # Patch the Gemfile to load plugins from our forks instead of upstream
        git am ../../manageiq-use-forked.patch
    fi
    for pr in $(jq ".${string_escaped_repo}[]" -r < "${PENDING_PRS}"); do
        git fetch origin "pull/${pr}/head"
        for sha in $(curl -u "${GIT_USER}:${GIT_PASSWORD}" "https://api.github.com/repos/ManageIQ/${repo}/pulls/${pr}/commits" | jq .[].sha -r); do
            git cherry-pick "${sha}"
        done
    done

    echo -e "\n\n\n** PUSHING REPO ${repo}**\n----------------------------------------------\n"
    git push --set-upstream "${GITHUB_ORG}" ${BRANCH} --force
    echo -e "\n** FINISHED REPO ${repo} **\n---------------------------------------------- \n"
    popd
done

echo "Cloning manageiq-pods..."
# FIXME: the clone URL for ManageIQ pods should be changed to upstream
# once the PR is merged: https://github.com/ManageIQ/manageiq-pods/pull/252
BUILD_TIME=$(date +%Y%m%d-%H%M)
git clone "https://github.com/elad661/manageiq-pods" -bghorg_arg
pushd manageiq-pods
git remote add "${GITHUB_ORG}" "git@github.com:${GITHUB_ORG}/manageiq-pods"
git checkout -b integration-build
pushd images

echo "Modifying Dockerfiles..."

pushd miq-app
mv Dockerfile Dockerfile.orig
sed "s/GHORG=ManageIQ/GHORG=${GITHUB_ORG}/g" < Dockerfile.orig > Dockerfile
echo "Modified miq-app dockerfile"
git diff Dockerfile
git add Dockerfile
popd

pushd miq-app-frontend
mv Dockerfile Dockerfile.orig
sed "s/GHORG=ManageIQ/GHORG=${GITHUB_ORG}/g" < Dockerfile.orig | sed "s/FROM manageiq\/manageiq-pods:backend-latest/FROM containermgmt\/manageiq-pods:build-${BUILD_TIME}/g" > Dockerfile
git diff Dockerfile
git add Dockerfile
popd

# FIXME for later:
# *actually* make sure each docker build contains just the PRs we wanted by using tags/named branches on the varius manageiq repos
# but for now, this will work, assuming nobody is going to run this script while a docker build is running
git commit -F- <<EOF
Automated image build ${BUILD_TIME}

Using PRs:
${PRS_JSON}
EOF
git tag "build-${BUILD_TIME}"
git push --force --tags ${GITHUB_ORG} integration-build
echo "Pushed manageiq-pods, 🐋dockerhub should do the rest."
echo "Good luck! 👍"
