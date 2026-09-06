#!/usr/bin/env bash

set -euo pipefail

JENKINS_HOME="${JENKINS_HOME:-/var/jenkins_home}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CASC_SOURCE="${REPO_ROOT}/jenkins-config/casc"
CASC_TARGET="${JENKINS_HOME}/casc"

echo "========================================="
echo " Jenkins Bootstrap"
echo "========================================="

echo "Jenkins Home : ${JENKINS_HOME}"
echo "Config Source: ${CASC_SOURCE}"
echo "Config Target: ${CASC_TARGET}"

mkdir -p "${CASC_TARGET}"

cp "${CASC_SOURCE}"/*.yaml "${CASC_TARGET}/"

echo ""
echo "JCasC configuration copied."

ls -lh "${CASC_TARGET}"

echo ""
echo "========================================="
echo " Bootstrap complete"
echo "========================================="