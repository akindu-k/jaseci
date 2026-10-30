#!/usr/bin/env bash
# Temporary probe for #10243: the seal precompile's codespace against its prepare.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAC_DEV_SOURCE="${REPO_ROOT}/jac"
jac --version || true
git -C "${REPO_ROOT}" log -1 --format='### source %h %s'

cd "${REPO_ROOT}"
status=0
for t in scripts/debug_10243_probe.jac jac/tests/compiler/test_precompiled_interfaces.jac jac/tests/compiler/test_iface_cache.jac; do
    echo "### test ${t}"
    timeout 2400 jac test "${t}" 2>&1 | tail -60
    rc=${PIPESTATUS[0]}
    echo "### exit ${t}: ${rc}"
    [ "${rc}" -eq 0 ] || status=1
done
exit "${status}"
