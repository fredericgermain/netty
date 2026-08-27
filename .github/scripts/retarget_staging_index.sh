#!/bin/bash
# ----------------------------------------------------------------------------
# Copyright 2026 The Netty Project
#
# The Netty Project licenses this file to you under the Apache License,
# version 2.0 (the "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at:
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
# ----------------------------------------------------------------------------
set -e

if [ "$#" -ne 3 ]; then
    echo "Expected local staging directory, server id and repository url"
    exit 1
fi

STAGING_DIR="$1"
SERVER_ID="$2"
URL="$3"

# nexus-staging-maven-plugin records the deployment target in the .index file it writes while
# staging, and deploy-staged replays it. Every line ends with ":<serverId>:<url>", so rewriting
# those two trailing fields is enough to send an already staged build somewhere else.
INDEX_FILES=$(find "${STAGING_DIR}" -name ".index")

if [ -z "${INDEX_FILES}" ]; then
    echo "No .index file found under ${STAGING_DIR}"
    exit 1
fi

for INDEX in ${INDEX_FILES}; do
    echo "Retargeting ${INDEX} to ${SERVER_ID} (${URL})"
    # The url contains slashes and colons, so use a separator that cannot appear in it.
    sed -i.bak -E "s|:[^:]+:[a-z]+://[^:]*\$|:${SERVER_ID}:${URL}|" "${INDEX}"
    rm -f "${INDEX}.bak"
done
