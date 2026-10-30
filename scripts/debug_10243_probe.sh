#!/usr/bin/env bash
# Temporary probe for #10243: the seal precompile's codespace against its prepare.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAC_DEV_SOURCE="${REPO_ROOT}/jac"
jac --version || true
git -C "${REPO_ROOT}" log -1 --format='### source %h %s'

cd "${REPO_ROOT}"
timeout 1800 jac test scripts/debug_10243_probe.jac 2>&1 | tail -80
exit "${PIPESTATUS[0]}"
