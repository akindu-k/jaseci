#!/usr/bin/env bash
# Runs every probe program under the bundled compiler (native and server
# placement) and the checkout compiler, printing output per program.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/scripts/debug_10556"
BUNDLED="$RUNNER_TEMP/bundled"
SERVER="$RUNNER_TEMP/server"
mkdir -p "$BUNDLED" "$SERVER"
cp "$SRC"/*.jac "$BUNDLED"/
cp "$SRC"/*.jac "$SERVER"/
printf '[project]\nname = "probe"\n' > "$BUNDLED/jac.toml"
printf '[project]\nname = "probe"\n\n[placement]\ndefault = "server"\n' > "$SERVER/jac.toml"

run_all() {
    local label="$1" dir="$2"
    for f in p1_issue_div p2_issue_bool p3_aug_variants p4_bool_variants; do
        echo "===== [$label] $f.jac"
        (cd "$dir" && timeout 900 jac run "$f.jac" 2>&1 | grep -v "removing unused runtime")
        echo "----- exit: ${PIPESTATUS[0]}"
    done
    echo "===== [$label] explain placement p1_issue_div.jac"
    (cd "$dir" && timeout 600 jac explain placement p1_issue_div.jac 2>&1 | head -40)
}

run_all "bundled-native" "$BUNDLED"
run_all "bundled-server" "$SERVER"
run_all "checkout" "$SRC"
