#!/bin/env/python3
# poll_dockercloud.py - Poll dockercloud to get build status
#
# Copyright © 2017 Red Hat Inc.
# Written by Elad Alfassa <ealfassa@redhat.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
"""
poll_dockercloud - Poll dockercloud to get build status

Usage:
  ./poll_dockercloud.py <build_id>

Options:
  -h --help     Show this screen.

Set the DOCKERCLOUD_USER and DOCKERCLOUD_PASS environment variables for authenticatation.
"""

import requests
import os
from time import sleep
from docopt import docopt
import json

DOCKERCLOUD_USER = os.getenv("DOCKERCLOUD_USER", None)
DOCKERCLOUD_PASS = os.getenv("DOCKERCLOUD_PASS", None)
AUTH = (DOCKERCLOUD_USER, DOCKERCLOUD_PASS)

BASE_URL = "https://cloud.docker.com"
REPO_URL = BASE_URL+"/api/repo/v1/repository/containermgmt/manageiq-pods/"
BUILD_URL = BASE_URL+"/api/build/v1/containermgmt/source/?image=containermgmt/manageiq-pods"


def poll_both_builds(build_id):
    """ Poll both backend and frontend builds """
    state = False
    print("Waiting for build to start")
    while state != "Building":
        sleep(10)
        response = requests.get(BUILD_URL, auth=AUTH)
        response.raise_for_status()
        response_json = response.json()["objects"][0]
        state = response_json["state"]
        if state == "Success" and build_tag_exists(build_id):
            raise SystemExit(0)
        print(".", end="", flush=True)

    backend, frontend = None, None
    for partial_url in response_json['build_settings']:
        url = BASE_URL + partial_url
        build_response = requests.get(url, auth=AUTH)
        build_response.raise_for_status()
        if 'backend' in build_response.json()['tag']:
            backend = url
        else:
            frontend = url
    print("\nWaiting for backend build...", flush=True)
    if poll_build_status(backend, build_id):
        print("\nBackend build complete! Waiting for frontend build...")
        poll_build_status(frontend, build_id, True)


def poll_build_status(url, build_id, wait_for_tag=False):
    """ Wait until a build is complete, and exit if it fails """
    state = "not started"
    while state in ["Building", "not started"]:
        sleep(5)
        response = requests.get(url, auth=AUTH)
        response.raise_for_status()
        print(".", end="", flush=True)
        state = response.json()["state"]
        if wait_for_tag:
            if state == "Success" and not build_tag_exists(build_id):
                state = "not started"
    if state == "Success":
        return True
    else:
        print("\nBuild failed!")
        print(json.dumps(response.json(), indent=4))
        raise SystemExit(1)


def build_tag_exists(build_id):
    """ Check if the expected tag exists for the provided build ID """
    response = requests.get(REPO_URL, auth=AUTH)
    response.raise_for_status()
    if response.json()["state"] == "Success":
        # Build successful?
        # maybe it's the previous build, verify we have the latest tag
        for tag in response.json()["tags"]:
            frontend_build = "frontend-{0}".format(build_id)
            if frontend_build in tag:
                print("\nTag exists, build successful!")
                return True
    return False


def main():
    arguments = docopt(__doc__)
    if not DOCKERCLOUD_USER or not DOCKERCLOUD_PASS:
        raise SystemExit("Authentication required")
    poll_both_builds(arguments["<build_id>"])


if __name__ == "__main__":
    main()
