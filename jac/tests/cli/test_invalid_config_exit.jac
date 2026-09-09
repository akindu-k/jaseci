"""Dispatch must reject an unresolvable jac.toml overlay with a clean exit."""

import os;
import from pathlib { Path }
import from tempfile { TemporaryDirectory }
import from jaclang.cli.commands.execution { _discover_config_from_file }
import from jaclang.cli.dispatch { _apply_overlay_or_exit }
import from jaclang.project.config { JacConfig }
import jaclang.project.config as config_mod;

glob BASE_TOML = "[project]\nname = \"overlay-exit\"\nversion = \"0.1.0\"\n";

"""Build a temp project whose prod overlay sets the given namespace value."""
def make_overlay_project(tmpdir: Path, namespace: str) -> JacConfig {
    (tmpdir / "jac.toml").write_text(BASE_TOML);
    (tmpdir / "jac.prod.toml").write_text(
        f"[scale.kubernetes]\nnamespace = \"{namespace}\"\n"
    );
    return JacConfig.load(tmpdir / "jac.toml");
}

test "unresolvable profile overlay exits cleanly" {
    config_mod._config = None;
    var_name = "JAC_TEST_OVERLAY_EXIT";
    cases = [
        (f"${{{var_name}}}", True),
        (f"${{{var_name}:?export {var_name}}}", True),
        (f"${{{var_name}:-fallback-ns}}", False)
    ];
    previous = os.environ.pop(var_name, None);
    try {
        for (namespace, should_exit) in cases {
            with TemporaryDirectory() as tmpdir {
                config = make_overlay_project(Path(tmpdir), namespace);
                exited = False;
                code: any = None;
                try {
                    _apply_overlay_or_exit(config, "prod");
                } except SystemExit as exc {
                    exited = True;
                    code = exc.code;
                }
                assert exited == should_exit , (
                    f"{namespace} exited={exited}, expected {should_exit}"
                );
                if should_exit {
                    assert code == 2 , f"expected exit code 2, got {code}";
                } else {
                    resolved = config.plugins["scale"]["kubernetes"]["namespace"];
                    assert resolved == "fallback-ns" , f"got {resolved}";
                }
            }
        }
    } finally {
        if previous is not None {
            os.environ[var_name] = previous;
        }
    }
}

"""Build a standalone project whose base jac.toml sets the given namespace."""
def make_base_project(tmpdir: Path, namespace: str) -> Path {
    (tmpdir / "jac.toml").write_text(
        BASE_TOML + f"\n[scale.kubernetes]\nnamespace = \"{namespace}\"\n"
    );
    src = tmpdir / "src";
    src.mkdir();
    entry_path = src / "main.jac";
    entry_path.write_text("with entry {\n    print(\"ran\");\n}\n");
    return entry_path;
}

test "unresolvable config in a file target exits cleanly" {
    config_mod._config = None;
    var_name = "JAC_TEST_TARGET_EXIT";
    cases = [
        (f"${{{var_name}}}", True),
        (f"${{{var_name}:?export {var_name}}}", True),
        (f"${{{var_name}:-fallback-ns}}", False)
    ];
    previous = os.environ.pop(var_name, None);
    try {
        for (namespace, should_exit) in cases {
            with TemporaryDirectory() as tmpdir {
                config_mod._config = None;
                entry_path = make_base_project(Path(tmpdir), namespace);
                exited = False;
                code: any = None;
                try {
                    _discover_config_from_file(str(entry_path));
                } except SystemExit as exc {
                    exited = True;
                    code = exc.code;
                }
                assert exited == should_exit , (
                    f"{namespace} exited={exited}, expected {should_exit}"
                );
                if should_exit {
                    assert code == 2 , f"expected exit code 2, got {code}";
                }
            }
        }
    } finally {
        config_mod._config = None;
        if previous is not None {
            os.environ[var_name] = previous;
        }
    }
}
