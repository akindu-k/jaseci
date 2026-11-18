#!/usr/bin/env bash
# Reproduce jaseci-labs/jac#10805: with one serve worker, /metrics omits the
# metrics an app records on prometheus_client's default registry.
set -uo pipefail

work=$(mktemp -d)
cat > "$work/jac.toml" <<'EOF'
[project]
name = "metrics-repro"
version = "0.1.0"

[scale.monitoring]
enabled = true
prometheus_admin_password = "scrape-secret"
EOF

cat > "$work/main.jac" <<'EOF'
import from prometheus_client { Counter, REGISTRY }

glob app_counter = Counter("repro_app_events_total", "events recorded by the app");

def:pub bump() -> dict[str, any] {
    app_counter.inc();
    return {"default_registry_value": REGISTRY.get_sample_value("repro_app_events_total")};
}
EOF

cat > "$work/probe_test.jac" <<'EOF'
import from prometheus_client { Counter, REGISTRY }
import from jaclang.scale.observability.prometheus_metrics { PrometheusMetricsCollector }

test "a single worker collector serves the app's default-registry metrics once" {
    app_counter = Counter("probe_app_events_total", "events the app records");
    try {
        app_counter.inc(3);
        collector = PrometheusMetricsCollector(config={"enabled": True, "namespace": "probe"});
        body = collector.expose().decode("utf-8");
        print(body);
        assert "probe_app_events_total 3.0" in body , "app metric missing from expose()";
        assert body.count("# TYPE process_cpu_seconds_total") == 1 , "process series not exactly once";
    } finally {
        REGISTRY.unregister(app_counter);
    }
}
EOF

status=0
for workers in 1 2; do
    port=$((8100 + workers))
    log="$work/serve-$workers.log"
    (cd "$work" && JAC_SERVE_WORKERS=$workers setsid jac run --serve --port "$port" main.jac >"$log" 2>&1) &
    up=0
    for _ in $(seq 1 300); do
        if curl -fs "http://localhost:$port/healthz" >/dev/null 2>&1; then up=1; break; fi
        sleep 1
    done
    if [ "$up" != 1 ]; then
        echo "::error::server with $workers worker(s) never came up"; cat "$log"; status=1; continue
    fi
    for _ in 1 2 3; do
        curl -s -X POST "http://localhost:$port/function/bump" -H 'content-type: application/json' -d '{}'; echo
    done
    body=$(curl -s -u admin:scrape-secret "http://localhost:$port/metrics")
    lines=$(grep -c '^repro_app_events_total' <<<"$body" || true)
    process_types=$(grep -c '^# TYPE process_cpu_seconds_total' <<<"$body" || true)
    jac_lines=$(grep -c '^metrics_repro_\|^jaclang_scale_\|^jac_info' <<<"$body" || true)
    echo "=== workers=$workers: repro_app_events_total lines=$lines, process_cpu TYPE lines=$process_types, scale/jac_info lines=$jac_lines"
    grep '^repro_app_events_total\|^jac_info' <<<"$body" || true
    if [ "$lines" = 0 ]; then
        echo "::error::workers=$workers: /metrics has no repro_app_events_total"
        status=1
    fi
    pkill -f "jac run --serve --port $port" || true
    sleep 2
done

echo "=== in-process collector check"
(cd "$work" && jac test probe_test.jac) || status=1
exit $status
