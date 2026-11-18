"""Debug-only probe for #10659: a from-imported os function under both stub lenses."""

import os;
import tempfile;
import from jaclang.compiler.driver.compile_options { CompileOptions }
import from jaclang.compiler.driver.program { JacProgram }
import from jaclang.compiler.frontend.codeinfo { bundled_stdlib_module_of }
import from jaclang.compiler.frontend.unitree { FuncCall, Module, Name }
import from jaclang.jac0core.stubcat_hook { active, set_active }

glob SOURCES: list[tuple[str, str]] = [
         (
             "from_import_alias",
             "import from os { replace as move }\n"
             "def:pub swap(a: str, b: str) -> int { move(a, b); return 1; }\n"
         ),
         (
             "attribute_control",
             "import os;\n"
             "def:pub swap(a: str, b: str) -> int { os.replace(a, b); return 1; }\n"
         )
     ];

def _probe(lens: str, label: str, src: str) -> list[str] {
    prog = JacProgram();
    compiler = prog._get_compiler();
    if lens == "trees" {
        set_active(None);
        compiler._stub_catalog = None;
        compiler._stub_catalog_tried = False;
        compiler.stub_catalog_disabled = True;
    }
    d = tempfile.mkdtemp(prefix="dbg10659_");
    path = os.path.join(d, f"{label}.jac");
    with open(path, "w") as f {
        f.write(src);
    }
    mod = prog.compile(
        file_path=path, options=CompileOptions(native_required=True, no_ir_cache=True)
    );
    lines: list[str] = [];
    lines.append(f"PROBE [{lens}/{label}] catalog_active={active() is not None}");
    for call in mod.get_all_sub_nodes(FuncCall) {
        target = call.target;
        if isinstance(target, Name) and target.sym is not None {
            scope = target.sym.parent_tab;
            if isinstance(scope, Module) {
                lines.append(
                    f"PROBE [{lens}/{label}] call {target.value}: sym={target.sym.sym_name} "
                    f"scope.name={scope.name!r} stub_only={scope.stub_only} "
                    f"mod_path={scope.loc.mod_path} "
                    f"bundled={bundled_stdlib_module_of(scope.loc.mod_path)!r}"
                );
            }
        }
    }
    lines.append(
        f"PROBE [{lens}/{label}] errors={[str(e) for e in prog.errors_had][:4]}"
    );
    ir_text = str(mod.gen.llvm_ir) if mod.gen.llvm_ir is not None else "";
    calls = [
        ln.strip()
        for ln in ir_text.splitlines()
        if " call " in ln and ("replace" in ln or "move" in ln)
    ];
    decls = [
        ln.strip()
        for ln in ir_text.splitlines()
        if ln.startswith("declare") and ("replace" in ln or "move" in ln)
    ];
    lines.append(f"PROBE [{lens}/{label}] ir_len={len(ir_text)} calls={calls[:4]}");
    lines.append(f"PROBE [{lens}/{label}] decls={decls[:4]}");
    return lines;
}

test "debug 10659: a from-imported os function lowers the same under both stub lenses" {
    saved = active();
    out: list[str] = [];
    try {
        for lens in ["catalog", "trees"] {
            for (label, src) in SOURCES {
                out.extend(_probe(lens, label, src));
            }
        }
    } finally {
        set_active(saved);
    }
    for ln in out {
        print(ln);
    }
    assert not [ln for ln in out if "errors=[" in ln and "errors=[]" not in ln] , (
        "a lens produced errors"
    );
}
