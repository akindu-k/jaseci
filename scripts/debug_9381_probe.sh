#!/usr/bin/env bash
# Temporary probe for #9381 / PR #9711: run both repros and the PR's three test
# files against one source tree, with or without the PR's production patch.
# LANE=before-reroute | after-reroute | before-sealed. Exits 0 always; verdicts
# are printed so every lane's full result is visible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANE="${LANE:?}"
echo "### lane=${LANE}"
jac --version || true

if [ "${LANE}" = "after-reroute" ]; then
    git -C "${REPO_ROOT}" apply scripts/debug_9381_prod.patch
    echo "### applied the PR's production patch"
    git -C "${REPO_ROOT}" diff --stat
fi

if [ "${LANE}" = "before-sealed" ]; then
    export JAC_NO_DEV_SOURCE=1
else
    export JAC_DEV_SOURCE="${REPO_ROOT}/jac"
fi

for repro in user_repro bg_writes caller_writes; do
    work="$(mktemp -d)"
    cp "${REPO_ROOT}/scripts/debug_9381_${repro}.jac" "${work}/"
    echo "### repro ${repro}"
    (cd "${work}" && timeout 1800 jac run --no-serve "debug_9381_${repro}.jac" 2>&1 | grep -v '^\s*$' | tail -20)
done

cd "${REPO_ROOT}/jac"
for t in test_context_isolation test_write_conflict test_read_path_isolation; do
    echo "### test ${t}"
    timeout 1800 jac test "tests/runtimelib/${t}.jac" 2>&1 | tail -40
    echo "### exit ${t}: ${PIPESTATUS[0]}"
done
