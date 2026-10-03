#!/usr/bin/env bash
# Temporary diagnostics for #9671: deploy a 2-worker app to kind and record
# where each app pod's prometheus multiprocess files live versus what /metrics serves.
set -uo pipefail

NS="${NS:-dbg9671}"
WORKERS="${WORKERS:-2}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$(mktemp -d)/metrics_workers"
cp -r "${REPO_ROOT}/jac/jaclang/scale/tests/fixtures/metrics_workers" "${APP_DIR}"
sed -i "s/^count = .*/count = ${WORKERS}/" "${APP_DIR}/jac.toml"
echo "### jac.toml"; cat "${APP_DIR}/jac.toml"

source "${REPO_ROOT}/jac/jaclang/scale/scripts/e2e_lib.sh"
kubectl create namespace "${NS}"
kubectl label namespace "${NS}" pod-security.kubernetes.io/enforce=privileged --overwrite
provision_kind_rwx_storage "${NS}" jac-rwx jac-rwx-bundle-pv /var/jac-rwx-bundle jac-rwx-perms

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

target = KubernetesTarget(
    config=KubernetesConfig(
        app_name="dbg", namespace="${NS}", container_port=8000,
        bundle_storage_class="jac-rwx", monitoring_enabled=False,
    ),
    logger=L(),
)
r = target.deploy(AppConfig(code_folder=".", app_name="dbg"))
print(f"deploy success={r.success}: {r.message}")
sys.exit(0 if r.success else 1)
PYEOF
deploy_rc=$?

kubectl get pods -n "${NS}" -o wide
for dep in $(kubectl get deployments -n "${NS}" -l managed=jac-scale -o name); do
    kubectl rollout status "${dep}" -n "${NS}" --timeout=600s || true
done
kubectl get pods -n "${NS}" -o wide
[ "${deploy_rc}" = 0 ] || echo "### deploy returned ${deploy_rc}, probing anyway"

IN_POD='
echo "--- id: $(id)"
echo "--- shell env: TMPDIR=${TMPDIR:-} PROMETHEUS_MULTIPROC_DIR=${PROMETHEUS_MULTIPROC_DIR:-} JAC_SERVE_WORKERS=${JAC_SERVE_WORKERS:-}"
echo "--- ls -la /tmp"; ls -la /tmp
for d in /tmp/jac-metrics-* /tmp/*/jac-metrics-*; do [ -d "$d" ] && { echo "--- dir $d"; ls -la --time-style=+%T "$d"; }; done
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  cmd=$(tr "\0" " " < $p/cmdline 2>/dev/null)
  [ -n "$cmd" ] || continue
  ppid=$(awk "/^PPid/{print \$2}" $p/status 2>/dev/null)
  echo "=== pid $pid ppid $ppid: $cmd"
  tr "\0" "\n" < $p/environ 2>/dev/null | grep -E "^(PROMETHEUS|prometheus|TMPDIR|JAC_SERVE|HOME)" | sed "s/^/   exec-env /"
  ls -l $p/fd 2>/dev/null | grep -E "jac-metrics|\.db" | sed "s/^/   fd /"
  grep -E "jac-metrics|\.db" $p/maps 2>/dev/null | awk "{print \"   map\", \$6, \$7}" | sort -u
done
echo "--- prometheus_client installs"
find / -xdev -maxdepth 9 -type d -name "prometheus_client*" 2>/dev/null
'

APP_PODS=$(kubectl get pods -n "${NS}" -l managed=jac-scale,jac-scale.role=microservice -o jsonpath='{.items[*].metadata.name}')
echo "### app pods: ${APP_PODS}"

probe() {
    local label="$1"
    for pod in ${APP_PODS}; do
        echo "################ ${label}: ${pod}"
        kubectl exec -n "${NS}" "${pod}" -c "$(kubectl get pod -n "${NS}" "${pod}" -o jsonpath='{.spec.containers[0].name}')" -- sh -c "${IN_POD}" 2>&1
    done
}

scrape() {
    local label="$1" port=18100
    for pod in ${APP_PODS}; do
        kubectl port-forward -n "${NS}" "pod/${pod}" "${port}:8000" >/dev/null 2>&1 &
        local pf=$!
        sleep 3
        echo "################ ${label}: scrape ${pod}"
        for i in 1 2 3 4 5 6; do
            curl -s -o /dev/null -w "ping %{http_code}\n" -X POST -H 'Content-Type: application/json' -d '{}' "http://localhost:${port}/walker/Ping" || true
            curl -s -o "/tmp/m_${pod}_${i}" -w "metrics %{http_code} bytes=%{size_download}\n" -u admin:scrape-secret "http://localhost:${port}/metrics" || true
        done
        echo "--- head of last body"; head -c 1500 "/tmp/m_${pod}_6"; echo
        kill "${pf}" 2>/dev/null; wait "${pf}" 2>/dev/null
        port=$((port + 1))
    done
}

probe "T0 after ready"
scrape "T0"
probe "T0 after traffic"
sleep 180
scrape "T+3m"
probe "T+3m"

for pod in ${APP_PODS}; do
    echo "################ logs ${pod}"
    kubectl logs -n "${NS}" "${pod}" --all-containers=true --timestamps --prefix 2>&1 | tail -400
done
kubectl get events -n "${NS}" --sort-by=.lastTimestamp | tail -60
exit 0
