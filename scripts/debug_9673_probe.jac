"""Temporary probe for #9673: the admin Logs page with logs off inside a cluster."""

import asyncio;
import os;
import from jaclang.scale.admin.logs { JacAPIServerLogs }
import from jaclang.scale.tests.support { RecordingHost }

obj ProbeHost(JacAPIServerLogs) {
    has server: any = None;

    def require_admin_json(Authorization: str | None) -> any {
        return None;
    }
}

obj ProbeRequest {
    has headers: dict[str, str] = {},
        query_params: dict[str, str] = {};
}

test "probe 9673: logs off inside a cluster still answers from the pods" {
    os.environ.pop("LOKI_URL", None);
    os.environ["KUBERNETES_SERVICE_HOST"] = "10.96.0.1";
    os.environ["K8S_APP_NAME"] = "probe";
    host = ProbeHost();
    host.server = RecordingHost();
    host.register_logs_endpoints();
    for path in ("/admin/logs", "/admin/logs/trace/{trace_id}") {
        ep = [e for e in host.server._endpoints if e.path == path][0];
        response = asyncio.run(
            ep.callback(ProbeRequest(), "abc12345")
                if "trace" in path
                else ep.callback(ProbeRequest())
        );
        print(f"### {path} -> {response.status_code} {response.body.decode()[:300]}");
        assert response.status_code != 502 , f"{path} reached for Loki with logs off";
    }
}
