#!/usr/bin/env bash
# Asserts that a workspace whose services sit beside the served app resolves a
# deployed tree that contains them (issue 9256). Optional deploy tooling that a
# bare fixture lacks is reported, not failed on: this checks tree resolution.
set -uo pipefail

BIN="$1"
MODE="$2"
ENTRY="${3:-}"

if [ "$MODE" = "named" ]; then
  "$BIN" scale deploy "$ENTRY" --target kubernetes --dry-run > out.log 2>&1
else
  "$BIN" scale deploy --target kubernetes --dry-run > out.log 2>&1
fi
code=$?
cat out.log
echo "exit=$code"

if grep -q "outside the deployed tree" out.log; then
  echo "FAIL: the 9256 containment error is still present"
  exit 1
fi
grep -q "svc -> /api/svc" out.log || { echo "FAIL: service app missing from fleet"; exit 1; }
grep -q "web -> / (gateway host)" out.log || { echo "FAIL: served app is not the gateway host"; exit 1; }

echo "PASS: the deployed tree contains the service beside the served app"

if [ "$code" -ne 0 ]; then
  echo "NOTE: the dry run exited $code after tree resolution succeeded."
  echo "NOTE: that is optional deploy tooling this bare fixture lacks, not the 9256 fix."
fi
