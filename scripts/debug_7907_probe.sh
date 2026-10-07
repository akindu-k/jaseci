#!/usr/bin/env bash
# Temporary probe for #7907: run the pooling and worker-budget tests against
# this checkout's jaclang source.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAC_DEV_SOURCE="${REPO_ROOT}/jac"
jac --version || true
git -C "${REPO_ROOT}" log -1 --format='### source %h %s'

cd "${REPO_ROOT}/jac"
status=0
for t in test_serving_client_errors test_serve_disconnect; do
    echo "### test ${t}"
    timeout 1800 jac test "tests/runtimelib/${t}.jac" 2>&1 | tail -60
    rc=${PIPESTATUS[0]}
    echo "### exit ${t}: ${rc}"
    [ "${rc}" -eq 0 ] || status=1
done
exit "${status}"
