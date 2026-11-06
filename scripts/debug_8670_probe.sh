#!/usr/bin/env bash
# Probe for #8670: what an app pod is told when the provisioned Postgres pod is unready,
# behind the headless Service main renders versus a plain ClusterIP Service.
set -uo pipefail
NS=probe8670
kubectl create namespace "$NS"

services() {
  kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata: {name: db-headless}
spec:
  selector: {app: db}
  ports: [{port: 5432, targetPort: 5432}]
  clusterIP: None
---
apiVersion: v1
kind: Service
metadata: {name: db-clusterip}
spec:
  selector: {app: db}
  ports: [{port: 5432, targetPort: 5432}]
YAML
}

statefulset() {
  local container="$1"
  kubectl -n "$NS" delete statefulset db --ignore-not-found --wait=true
  kubectl -n "$NS" delete pod db-0 --ignore-not-found --wait=true
  kubectl -n "$NS" apply -f - <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: db}
spec:
  serviceName: db-headless
  replicas: 1
  selector: {matchLabels: {app: db}}
  template:
    metadata: {labels: {app: db}}
    spec:
      containers:
$container
YAML
}

connect() {
  local host="$1"
  kubectl -n "$NS" run "client-$RANDOM" --rm -i --restart=Never --quiet --image=python:3.12-slim -- \
    python -c "
import socket
try:
    socket.create_connection(('$host', 5432), timeout=10).close()
    print('$host -> CONNECTED')
except Exception as e:
    print('$host ->', type(e).__name__ + ':', e)
" 2>&1 | grep -- '->'
}

probe() {
  local label="$1"
  echo "=== $label"
  kubectl -n "$NS" get pods -l app=db -o wide
  kubectl -n "$NS" get endpoints db-headless db-clusterip
  connect db-headless | tee -a "/tmp/probe-$label.txt"
  connect db-clusterip | tee -a "/tmp/probe-$label.txt"
}

services
kubectl -n "$NS" run warm --restart=Never --image=python:3.12-slim -- sleep 1 && kubectl -n "$NS" wait --for=condition=Ready=false pod/warm --timeout=120s || true
kubectl -n "$NS" delete pod warm --ignore-not-found
kubectl -n "$NS" create secret generic pw --from-literal=password=pw

echo "##### scenario: postgres aborts on start (the disk-full crashloop shape)"
statefulset '      - name: postgres
        image: postgres:18
        command: ["sh", "-c", "echo could not write to file: No space left on device; exit 14"]
        ports: [{containerPort: 5432}]'
sleep 45
probe crashloop

echo "##### scenario: postgres runs but readiness fails (pg_isready-style probe failing)"
statefulset '      - name: postgres
        image: postgres:18
        env: [{name: POSTGRES_PASSWORD, value: pw}]
        ports: [{containerPort: 5432}]
        readinessProbe: {exec: {command: ["false"]}, periodSeconds: 5}'
sleep 45
probe unready

echo "##### scenario: healthy postgres, then migrate the headless Service to ClusterIP in place"
statefulset '      - name: postgres
        image: postgres:18
        env: [{name: POSTGRES_PASSWORD, value: pw}]
        ports: [{containerPort: 5432}]
        readinessProbe: {exec: {command: ["pg_isready", "-U", "postgres"]}, periodSeconds: 5}'
kubectl -n "$NS" rollout status statefulset/db --timeout=180s
probe healthy-before
echo "--- clusterIP is immutable; patching it must be rejected:"
kubectl -n "$NS" patch service db-headless -p '{"spec":{"clusterIP":""}}' 2>&1 || true
kubectl -n "$NS" delete service db-headless
kubectl -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata: {name: db-headless}
spec:
  selector: {app: db}
  ports: [{port: 5432, targetPort: 5432}]
YAML
kubectl -n "$NS" get service db-headless
probe healthy-after-migration
kubectl -n "$NS" get statefulset db

echo "##### verdict"
fail=0
grep -q "db-headless -> gaierror" /tmp/probe-crashloop.txt || { echo "headless crashloop did not yield gaierror"; fail=1; }
grep -q "db-headless -> gaierror" /tmp/probe-unready.txt || { echo "headless unready did not yield gaierror"; fail=1; }
grep -q "db-clusterip -> ConnectionRefusedError" /tmp/probe-crashloop.txt || { echo "clusterip crashloop not refused"; fail=1; }
grep -q "db-clusterip -> ConnectionRefusedError" /tmp/probe-unready.txt || { echo "clusterip unready not refused"; fail=1; }
grep -q "db-headless -> CONNECTED" /tmp/probe-healthy-after-migration.txt || { echo "migrated service unreachable"; fail=1; }
exit $fail
