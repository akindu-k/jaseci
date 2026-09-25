#!/usr/bin/env bash
# Usage: verify_9195.sh <jac-binary> <label>
# Builds a web app twice (the second build changes only the page text),
# serves each build from its .jab, and checks the page shell's validators.
set -uo pipefail
JAC="$1"; LABEL="$2"; PORT="${PORT:-8791}"; B="http://localhost:$PORT"
WORK="$(mktemp -d)"; cd "$WORK"
export HOME="$WORK/home"; mkdir -p "$HOME"

"$JAC" --version
"$JAC" create etagrepro --kind web-app > create.log 2>&1 || { cat create.log; exit 2; }
cd etagrepro
"$JAC" install > install.log 2>&1 || { tail -40 install.log; exit 2; }

build_and_serve() {
  sed -i "s|<h1>.*</h1>|<h1>$1</h1>|" frontend.jac
  "$JAC" build > build.log 2>&1 || { tail -40 build.log; exit 2; }
  "$JAC" run --port "$PORT" dist/etagrepro.jab > serve.log 2>&1 &
  SERVER=$!
  for _ in $(seq 1 120); do curl -s -o /dev/null "$B/healthz/live" && return; sleep 1; done
  tail -40 serve.log; exit 2
}
stop() { kill "$SERVER"; wait "$SERVER" 2>/dev/null; }
hdr() { curl -s -o /dev/null -D - -H 'Accept: text/html' "$@" "$B/board" | awk -F': ' -v k="$HDR" 'tolower($1)==k{print $2}' | tr -d '\r'; }
code() { curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/html' "$@" "$B/board"; }
bundle() { curl -s -H 'Accept: text/html' "$B/board" | grep -oE 'client\.[A-Za-z0-9_-]+\.js' | head -1; }

build_and_serve "build one"
ETAG1="$(HDR=etag hdr)"; BUNDLE1="$(bundle)"; LM1="$(HDR=last-modified hdr)"
stop

build_and_serve "build two"
ETAG2="$(HDR=etag hdr)"; BUNDLE2="$(bundle)"; LM2="$(HDR=last-modified hdr)"
OLD_INM="$(code -H "If-None-Match: $ETAG1")"
NEW_INM="$(code -H "If-None-Match: $ETAG2")"
IMS="$(code -H 'If-Modified-Since: Tue, 01 Sep 2026 00:00:00 GMT')"
stop

cat <<EOF
== $LABEL
build 1: bundle=$BUNDLE1 etag=$ETAG1 last-modified=${LM1:-<none>}
build 2: bundle=$BUNDLE2 etag=$ETAG2 last-modified=${LM2:-<none>}
build 2, If-None-Match from build 1 -> $OLD_INM
build 2, If-None-Match from build 2 -> $NEW_INM
build 2, If-Modified-Since 2026-09-01 -> $IMS
EOF

[ "$BUNDLE1" != "$BUNDLE2" ] || { echo "setup: bundles did not differ"; exit 2; }
if [ "$ETAG1" != "$ETAG2" ] && [ "$OLD_INM" = 200 ] && [ "$NEW_INM" = 304 ] && [ "$IMS" = 200 ] && [ -z "$LM2" ]; then
  echo "RESULT($LABEL): FIXED"; exit 0
fi
echo "RESULT($LABEL): STALE SHELL"; exit 1
