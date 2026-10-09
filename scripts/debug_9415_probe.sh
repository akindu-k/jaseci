#!/usr/bin/env bash
# Each probe breaks the fix in the checkout and asserts the named test fails.
set -uo pipefail
cd "$GITHUB_WORKSPACE/jac"
SERVE=jaclang/server/sealed_serve.jac
SEAL=jaclang/dist/seal.jac
PREP=tests/compiler/test_application_preparation.jac
SEALED=tests/client/test_sealed_serve.jac
WRITER=colocated
READER=baked
OWN_MOD=own_mod
status=0

run() {
  HOME="$(mktemp -d)" jac test -v "$1" -f "$2" > /tmp/probe.log 2>&1
  local code=$?
  tail -n 60 /tmp/probe.log
  return $code
}

expect() {
  local label="$1" outcome="$2" file="$3" filter="$4" needle="${5:-}"
  echo "::group::$label"
  run "$file" "$filter"
  local code=$?
  echo "::endgroup::"
  if [ "$outcome" = pass ] && [ $code -ne 0 ]; then
    echo "::error::$label: expected pass, got exit $code"; status=1; return
  fi
  if [ "$outcome" = fail ] && [ $code -eq 0 ]; then
    echo "::error::$label: expected the test to fail, it passed"; status=1; return
  fi
  if [ -n "$needle" ] && ! grep -qF "$needle" /tmp/probe.log; then
    echo "::error::$label: output does not mention '$needle'"; status=1; return
  fi
  echo "OK  $label ($outcome)"
}

mutate() { python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
assert text.count(old) == 1, f"{old!r} not unique in {path}"
open(path, "w").write(text.replace(old, new))
PY
}

restore() { git checkout -- "$SERVE" "$SEAL"; }

expect "baseline writer" pass "$PREP" "$WRITER" "$WRITER"
expect "baseline reader" pass "$PREP" "$READER" "$READER"
expect "baseline serve_manifest_for" pass "$SEALED" "$OWN_MOD" "$OWN_MOD"

mutate "$SERVE" "if meta.get('format') != SERVE_MANIFEST_FORMAT {" "if False {"
expect "M1 format check disabled -> reader" fail "$PREP" "$READER" "serve manifest format unstamped"
expect "M1 format check disabled -> serve_manifest_for" fail "$SEALED" "$OWN_MOD" "serve manifest format unstamped"
restore

mutate "$SEAL" "result.update(serve_manifest_stamp());" "result.update(serve_manifest_stamp());
        result['undeclared_key'] = 1;"
expect "M2 new key without a format decision" fail "$PREP" "$WRITER" "serve manifest shape changed"
restore

mutate "$SERVE" "SERVE_MANIFEST_FORMAT: int = 3" "SERVE_MANIFEST_FORMAT: int = 4"
expect "M3 format bumped without recording the shape" fail "$PREP" "$WRITER" "serve manifest shape changed"
restore

mutate "$SEAL" "result.update(serve_manifest_stamp());" ""
expect "M4 writer drops the stamp" fail "$PREP" "$WRITER"
restore

exit $status
