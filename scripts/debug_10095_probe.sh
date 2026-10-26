#!/usr/bin/env bash
# Temporary probe for #10095: run the bundle keep-set and seed prune tests
# against this checkout's jaclang source.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAC_DEV_SOURCE="${REPO_ROOT}/jac"
jac --version || true
git -C "${REPO_ROOT}" log -1 --format='### source %h %s'

cd "${REPO_ROOT}"
status=0
for t in deploy/test_superseded_deployment_reap microservices/test_pvc_injector; do
    echo "### test ${t}"
    timeout 1800 jac test "jac/jaclang/scale/tests/${t}.jac" 2>&1 | tail -80
    rc=${PIPESTATUS[0]}
    echo "### exit ${t}: ${rc}"
    [ "${rc}" -eq 0 ] || status=1
done
exit "${status}"
