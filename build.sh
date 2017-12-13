#!/usr/bin/env bash

# "Bash strict mode" settings - http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -e          # exit on error (like a normal programming langauge)
set -u          # fail when undefined variables are used
set -o pipefail # prevent errors in a pipeline from being masked

BRANCH=image-unstable
PENDING_PRS=${PWD}/pending-prs-unstable.json
BUILD_ID=${BUILD_ID:-}
BASEDIR=${PWD}/manageiq-unstable
CORE_REPO=manageiq
GITHUB_ORG=container-mgmt
PRS_JSON=$(jq -Mc . "${PENDING_PRS}")
BUILD_TIME=$(date +%Y%m%d-%H%M)
COMMITSTR=""
TAG="patched-${BUILD_TIME}"
export TAG  # needs to be exported for use with envsubst later

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

# Remove merged PRs from the list to avoid conflicts
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 python2 manageiq_prs.py remove_merged

if [ ! -d "${BASEDIR}" ]; then
    mkdir "${BASEDIR}"
fi
cd "${BASEDIR}"

# Read repo list from the pending PRs json
repos=$(jq "keys[]" -r "${PENDING_PRS}")

for repo in ${repos}; do
    echo -e "\n\n\n** DOING REPO ${repo}**\n----------------------------------------------\n"
    if [ -d "${repo}" ]; then
        echo "${repo} is already cloned, updating"
        pushd "${repo}"
        # Clean up the repo and make sure it's in sync with upstream master
        git checkout master
        git clean -xdf
        git reset HEAD --hard
        git branch -D ${BRANCH}
        git pull origin master
    else
        git clone "https://github.com/ManageIQ/${repo}"
        pushd "${repo}"
        git remote add "${GITHUB_ORG}" "git@github.com:${GITHUB_ORG}/${repo}"
    fi

    # Save the HEAD ref, so we know which upstream commit was the latest
    # when we rolled the build.
    MASTER_HEAD=$(git rev-parse --short HEAD)
    echo "Master is: ${MASTER_HEAD}"
    COMMITSTR="${COMMITSTR}"$'\n'"${repo} master HEAD was ${MASTER_HEAD}"

    # tag this HEAD to mark it was the HEAD for the current BUILD_TIME
    git tag "head-${BUILD_TIME}"
    # make sure our master is up to date with upstream, so the tag would be meaningful
    git push --tags ${GITHUB_ORG} master

    #weird bash hack
    string_escaped_repo=\"${repo}\"

    git checkout -b ${BRANCH}
    if [ "${repo}" == "${CORE_REPO}" ]; then
        # Patch the Gemfile to load plugins from our forks instead of upstream
        envsubst < ../../manageiq-use-forked.patch.in > manageiq-use-forked.patch
        git am manageiq-use-forked.patch
    fi
    for pr in $(jq ".${string_escaped_repo}[]" -r < "${PENDING_PRS}"); do
        git fetch origin "pull/${pr}/head"
        for sha in $(curl -u "${GIT_USER}:${GIT_PASSWORD}" "https://api.github.com/repos/ManageIQ/${repo}/pulls/${pr}/commits" | jq .[].sha -r); do
            git cherry-pick "${sha}"
        done
    done

    echo -e "\n\n\n** PUSHING REPO ${repo}**\n----------------------------------------------\n"
    git tag "${TAG}"
    git push --set-upstream --tags "${GITHUB_ORG}" ${BRANCH} --force
    echo -e "\n** FINISHED REPO ${repo} **\n---------------------------------------------- \n"
    popd
done

echo "Cloning manageiq-pods..."
if [ -d "manageiq-pods" ]; then
    pushd manageiq-pods
    git checkout ghorg_arg  # FIXME this should be master
    git clean -xdf
    git reset HEAD --hard
    git pull origin master
else
    # FIXME: the clone URL for ManageIQ pods should be changed to upstream
    # once the PR is merged: https://github.com/ManageIQ/manageiq-pods/pull/252
    git clone "https://github.com/elad661/manageiq-pods" -bghorg_arg
    pushd manageiq-pods
    git remote add "${GITHUB_ORG}" "git@github.com:${GITHUB_ORG}/manageiq-pods"
fi
pushd images

echo -e "\nModifying Dockerfiles...\n"

# Copy dockerfiles from master to use as base for modifications
pushd miq-app
cp Dockerfile Dockerfile.orig
popd
pushd miq-app-frontend
cp Dockerfile Dockerfile.orig
popd

# Now checkout the integration-build branch so we can update the dockerfiles
# in a way that keeps their git history

git fetch "${GITHUB_ORG}"
git checkout integration-build

pushd miq-app
# Note: we modify the URL for the manageiq tarball instead of modifying REF
# because we don't patch manageiq-appliance
sed "s/GHORG=ManageIQ/GHORG=${GITHUB_ORG}/g" < Dockerfile.orig | sed 's/manageiq\/tarball\/${REF}/manageiq\/tarball\/image-unstable/g' > Dockerfile
echo "Modified miq-app dockerfile"
git diff Dockerfile
git add Dockerfile
popd

pushd miq-app-frontend
# Not setting GHORG here because we don't patch manageiq-ui-service
sed "s/FROM manageiq\/manageiq-pods:backend-latest/FROM containermgmt\/manageiq-pods:backend-${BUILD_TIME}/g" < Dockerfile.orig > Dockerfile
git diff Dockerfile
git add Dockerfile
popd

git commit -F- <<EOF
Automated image build ${BUILD_TIME}
Jenkins ID: ${BUILD_ID}

Using PRs:
${PRS_JSON}

Base refs: ${COMMITSTR}
EOF
# We need two tags (instead of just one) to force the DockerHub automated build
# to build two images from the same repository. It's a bit of a hack, but
# that's what the ManageIQ people do for their builds as well.
git tag "backend-${BUILD_TIME}"
git push --force --tags ${GITHUB_ORG} integration-build
sleep 15  # HACK: push the backend tag first in hopes DockerHub will build it before building the frontend tag
git tag "frontend-${BUILD_TIME}"
git push --force --tags ${GITHUB_ORG} integration-build
echo "Pushed manageiq-pods, 🐋dockerhub/dockercloud should do the rest."
if [ ! -z "${DOCKERCLOUD_PASS}" ]; then
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 python2 poll_dockercloud.py "${BUILD_TIME}"
fi
