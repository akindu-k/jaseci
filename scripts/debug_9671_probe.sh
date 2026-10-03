#!/usr/bin/env bash
# Temporary diagnostics for #9671: deploy a multi-worker app to kind under one
# scenario, drive traffic, and record where each app pod's prometheus multiprocess
# files live versus what /metrics serves. Exits 1 if any scrape body is empty.
set -uo pipefail

SCENARIO="${SCENARIO:-baseline}"
WORKERS="${WORKERS:-2}"
REPLICAS="${REPLICAS:-1}"
MAX_REQUESTS="${MAX_REQUESTS:-0}"
EXTRA_DEP="${EXTRA_DEP:-}"
EXTERNAL_DB="${EXTERNAL_DB:-0}"
DURATION_MIN="${DURATION_MIN:-6}"
PINGS_PER_CYCLE="${PINGS_PER_CYCLE:-10}"
NS=dbg9671
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$(mktemp -d)/metrics_workers"
SCRAPES="$(mktemp)"

echo "### scenario=${SCENARIO} workers=${WORKERS} replicas=${REPLICAS} max_requests=${MAX_REQUESTS} extra_dep='${EXTRA_DEP}' external_db=${EXTERNAL_DB} duration=${DURATION_MIN}m"

cp -r "${REPO_ROOT}/jac/jaclang/scale/tests/fixtures/metrics_workers" "${APP_DIR}"
sed -i "s/^count = .*/count = ${WORKERS}/" "${APP_DIR}/jac.toml"
if [ -n "${EXTRA_DEP}" ]; then
    printf '\n[dependencies]\n%s\n' "${EXTRA_DEP}" >> "${APP_DIR}/jac.toml"
fi
echo "### jac.toml"; cat "${APP_DIR}/jac.toml"

source "${REPO_ROOT}/jac/jaclang/scale/scripts/e2e_lib.sh"
kubectl create namespace "${NS}"
kubectl label namespace "${NS}" pod-security.kubernetes.io/enforce=privileged --overwrite
provision_kind_rwx_storage "${NS}" jac-rwx jac-rwx-bundle-pv /var/jac-rwx-bundle jac-rwx-perms

DB_URL=""
if [ "${EXTERNAL_DB}" = 1 ]; then
    kubectl create namespace extdb
    kubectl -n extdb apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: pg }
spec:
  replicas: 1
  selector: { matchLabels: { app: pg } }
  template:
    metadata: { labels: { app: pg } }
    spec:
      containers:
        - name: pg
          image: postgres:16
          env:
            - { name: POSTGRES_USER, value: jac }
            - { name: POSTGRES_PASSWORD, value: jac }
            - { name: POSTGRES_DB, value: jac }
          ports: [ { containerPort: 5432 } ]
---
apiVersion: v1
kind: Service
metadata: { name: pg }
spec:
  selector: { app: pg }
  ports: [ { port: 5432, targetPort: 5432 } ]
YAML
    kubectl -n extdb rollout status deploy/pg --timeout=300s
    DB_URL="postgresql://jac:jac@pg.extdb.svc.cluster.local:5432/jac"
fi

cd "${APP_DIR}"
jac - <<PYEOF
import sys
from jaclang.scale.deploy.target.kubernetes.target import KubernetesTarget
from jaclang.scale.deploy.target.kubernetes.kubernetes_config import KubernetesConfig
from jaclang.scale.config.app_config import AppConfig

class L:
    def info(self, m, *a, **k): print(f"INFO: {m}", file=sys.stderr)
    def warn(self, m, *a, **k): print(f"WARN: {m}", file=sys.stderr)
    warning = warn
    def error(self, m, *a, **k): print(f"ERROR: {m}", file=sys.stderr)
    def debug(self, m, *a, **k): pass

cfg = dict(app_name="dbg", namespace="${NS}", container_port=8000,
           bundle_storage_class="jac-rwx", monitoring_enabled=False)
if "${DB_URL}":
    cfg.update(database_mode="external", database_url="${DB_URL}")
env = {}
if int("${MAX_REQUESTS}") > 0:
    env["JAC_SERVE_MAX_REQUESTS"] = "${MAX_REQUESTS}"
overrides = {}
if int("${REPLICAS}") > 1:
    overrides = {k: {"replicas": int("${REPLICAS}")} for k in ("metrics_workers", "metrics-workers")}
target = KubernetesTarget(config=KubernetesConfig(**cfg), env=env, app_overrides=overrides, logger=L())
r = target.deploy(AppConfig(code_folder=".", app_name="dbg"))
print(f"deploy success={r.success}: {r.message}")
sys.exit(0 if r.success else 1)
PYEOF
deploy_rc=$?

for dep in $(kubectl get deployments -n "${NS}" -l managed=jac-scale -o name); do
    kubectl rollout status "${dep}" -n "${NS}" --timeout=600s || true
done
kubectl get pods -n "${NS}" -o wide
[ "${deploy_rc}" = 0 ] || echo "### deploy returned ${deploy_rc}, probing anyway"

IN_POD='
echo "--- id: $(id)  date: $(date -u +%T)"
echo "--- ls -la /tmp"; ls -la /tmp
for d in /tmp/jac-metrics-* /tmp/*/jac-metrics-*; do [ -d "$d" ] && { echo "--- dir $d"; ls -la "$d"; }; done
for p in /proc/[0-9]*; do
  cmd=$(tr "\0" " " < $p/cmdline 2>/dev/null)
  [ -n "$cmd" ] || continue
  case "$cmd" in sh\ -c*) continue;; esac
  echo "=== pid ${p#/proc/} ppid $(awk "/^PPid/{print \$2}" $p/status 2>/dev/null): $cmd"
  tr "\0" "\n" < $p/environ 2>/dev/null | grep -E "^(PROMETHEUS|prometheus|TMPDIR|JAC_SERVE_WORKERS|JAC_SERVE_MAX)" | sed "s/^/   exec-env /"
  ls -l $p/fd 2>/dev/null | grep -E "jac-metrics|\.db" | awk "{print \"   fd\", \$NF}" | sort -u
done
echo "--- prometheus_client copies"
find / -xdev -type d -name "prometheus_client*" 2>/dev/null | grep -v "^/proc"
'

app_pods() {
    kubectl get pods -n "${NS}" -l managed=jac-scale,jac-scale.role=microservice \
        --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'
}

probe() {
    local label="$1"
    for pod in $(app_pods); do
        echo "################ ${label}: ${pod}"
        kubectl exec -n "${NS}" "${pod}" -- sh -c "${IN_POD}" 2>&1
    done
}

cycle() {
    local label="$1" port=18100
    for pod in $(app_pods); do
        kubectl port-forward -n "${NS}" "pod/${pod}" "${port}:8000" >/dev/null 2>&1 &
        local pf=$!
        sleep 2
        local ok=0 fail=0
        for _ in $(seq 1 "${PINGS_PER_CYCLE}"); do
            code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{}' "http://localhost:${port}/walker/Ping" || echo 000)
            [ "${code}" = 200 ] && ok=$((ok + 1)) || fail=$((fail + 1))
        done
        for i in 1 2 3; do
            out=$(curl -s -o "/tmp/body_${pod}" -w "%{http_code} %{size_download}" -u admin:scrape-secret "http://localhost:${port}/metrics" || echo "000 0")
            echo "${label} ${pod} pings_ok=${ok} pings_fail=${fail} scrape${i}=${out}" | tee -a "${SCRAPES}"
            if [ "${out}" = "200 0" ]; then
                echo "::error::EMPTY /metrics body from ${pod} at ${label}"
                probe "EMPTY at ${label}"
            fi
        done
        kill "${pf}" 2>/dev/null; wait "${pf}" 2>/dev/null
        port=$((port + 1))
    done
}

probe "T0"
cycle "T0"
end=$(( $(date +%s) + DURATION_MIN * 60 ))
n=0
while [ "$(date +%s)" -lt "${end}" ]; do
    n=$((n + 1))
    cycle "cycle${n}@$(( (end - $(date +%s)) / 60 ))m-left"
    sleep 20
done
probe "END"
echo "--- last body head"; for f in /tmp/body_*; do echo "== $f"; head -c 1200 "$f"; echo; done

for pod in $(app_pods); do
    echo "################ logs ${pod}"
    kubectl logs -n "${NS}" "${pod}" --all-containers=true --timestamps --prefix 2>&1 | grep -av "GET /healthz" | tail -300
done
kubectl get pods -n "${NS}" -o wide

total=$(wc -l < "${SCRAPES}")
empty=$(grep -c " 200 0$" "${SCRAPES}" || true)
echo "### SUMMARY scenario=${SCENARIO}: ${total} scrapes, ${empty} empty"
[ "${empty}" = 0 ] || exit 1
