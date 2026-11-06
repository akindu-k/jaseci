#!/usr/bin/env bash
# Temporary probe for PR 10451: one codespace per sealed app, including workspace members.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAC_DEV_SOURCE="${REPO_ROOT}/jac"
jac --version || true
git -C "${REPO_ROOT}" log -1 --format='### source %h %s'

cd "${REPO_ROOT}"
status=0
for t in jac/tests/compiler/test_precompiled_interfaces.jac jac/tests/compiler/test_iface_cache.jac jac/tests/cli/test_precompile_discovery.jac; do
    echo "### test ${t}"
    timeout 2400 jac test "${t}" 2>&1 | tail -80
    rc=${PIPESTATUS[0]}
    echo "### exit ${t}: ${rc}"
    [ "${rc}" -eq 0 ] || status=1
done
exit "${status}"
