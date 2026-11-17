#!/usr/bin/env bash
# Temporary probe for #9673: what /admin/logs answers with logs off inside a cluster.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAC_DEV_SOURCE="${REPO_ROOT}/jac"
jac --version || true
git -C "${REPO_ROOT}" log -1 --format='### source %h %s'

cd "${REPO_ROOT}"
status=0
for t in scripts/debug_9673_probe.jac jac/jaclang/scale/tests/server/test_admin_logs.jac; do
    echo "### test ${t}"
    timeout 1800 jac test "${t}" 2>&1 | tail -60
    rc=${PIPESTATUS[0]}
    echo "### exit ${t}: ${rc}"
    [ "${rc}" -eq 0 ] || status=1
done
exit "${status}"
