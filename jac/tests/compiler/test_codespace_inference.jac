"""Tests for markerless codespace inference.

Covers the full pipeline: parse-time seeding (JSX / string-path imports),
symbol-based propagation in CodespacePullPass (scope-aware, exclusion policy),
the placement-vs-boundary edge model for `sv` imports, and the design rule
that native placement is explicit-only.
"""

import os;
import from tests.support { JAC_ROOT }
import jaclang;
import jaclang.jac0core.unitree as uni;
import from jaclang.jac0core.program { JacProgram }

glob FIXTURE_DIR = os.path.join(
         JAC_ROOT, "tests", "compiler", "fixtures", "codespace"
     );

"""Compile a codespace fixture; stamps only (no codegen) unless cgen=True."""
def compile_fixture(name: str, cgen: bool = False) -> object {
    prog = JacProgram();
    mod = prog.compile(os.path.join(FIXTURE_DIR, name), no_cgen=not cgen);
    assert not prog.errors_had , f"{name}: {[str(e) for e in prog.errors_had]}";
    return mod;
}

"""Find a top-level element by declared name and return its stamped context."""
def stamp_of(mod: uni.Module, name: str) -> str {
    for stmt in mod.body {
        found = False;
        if (isinstance(stmt, uni.Ability) and isinstance(stmt.name_ref, uni.Name)) {
            found = stmt.name_ref.value == name;
        } elif isinstance(stmt, (uni.Archetype, uni.Enum)) {
            found = stmt.name.value == name;
        } elif isinstance(stmt, uni.GlobalVars) {
            for assign in stmt.assignments {
                for tgt in assign.target {
                    if (isinstance(tgt, uni.Name) and tgt.value == name) {
                        found = True;
                    }
                }
            }
        } elif isinstance(stmt, uni.Import) {
            for item in stmt.items {
                if (
                    isinstance(item, uni.ModuleItem)
                    and isinstance(item.name, uni.Name)
                    and item.name.value == name
                ) {
                    found = True;
                } elif (
                    isinstance(item, uni.ModulePath)
                    and item.path
                    and isinstance(item.path[0], uni.Name)
                    and item.path[0].value == name
                ) {
                    found = True;
                }
            }
        }
        if found {
            return str(stmt.code_context);
        }
    }
    return 'missing';
}

test "markerless client module seeds and pulls" {
    mod = compile_fixture("infer_client_app.jac");
    assert stamp_of(mod, "clsx") == 'client' , "npm import should seed client";
    assert stamp_of(mod, "app") == 'client' , "JSX def should seed client";
    assert stamp_of(mod, "css_helper") == 'client' , "helper using npm import should be pulled client";
    assert stamp_of(mod, "click_count") == 'client' , "glob referenced from client should be pulled client";
}

test "three codespaces in one markerless module" {
    mod = compile_fixture("infer_three_spaces.jac");
    assert stamp_of(mod, "app") == 'client' , "JSX def should infer client";
    assert stamp_of(mod, "server_stats") == 'server' , "def:pub is a server endpoint, not relocated by client calls";
    assert stamp_of(mod, "Item") == 'server' , "node archetype stays server (auto-shared, never pulled)";
    assert stamp_of(mod, "list_items") == 'server' , "walker stays server (spawned via RPC)";
    assert stamp_of(mod, "os") == 'server' , "python import stays server";
    has_native_block = False;
    for stmt in mod.body {
        if isinstance(stmt, uni.NativeBlock) {
            has_native_block = True;
            for inner in stmt.body {
                if isinstance(inner, uni.ContextAwareNode) {
                    assert str(inner.code_context) == 'native' , "na block contents are native";
                }
            }
        }
    }
    assert has_native_block , "explicit na block should be preserved";
}

test "mixed module generates rpc bridges in js" {
    mod = compile_fixture("infer_three_spaces.jac", cgen=True);
    js = mod.gen.js;
    assert js.strip() , "client side of mixed module should generate JS";
    assert '__jacCallFunction("server_stats"' in js , "client call to def:pub becomes RPC";
    assert '__jacSpawn("list_items"' in js , "client spawn of walker becomes RPC spawn";
    assert 'fast_add' not in js , "native block must not leak into JS";
}

test "sv import placement is inferred while boundary fact stays" {
    mod = compile_fixture("infer_sv_client.jac", cgen=True);
    assert stamp_of(mod, "fetch_items") == 'client' , "client-consumed sv import is placed client";
    assert stamp_of(mod, "app") == 'client';
    assert stamp_of(mod, "local_report") == 'server' , "using an sv-imported name must not pull the caller client";
    js = mod.gen.js;
    assert '__jacCallFunction("fetch_items"' in js , "sv import in client placement generates RPC stub";
}

test "locals shadowing client names do not pull" {
    mod = compile_fixture("infer_shadowing.jac");
    assert stamp_of(mod, "styled") == 'client' , "real use of npm import pulls client";
    assert stamp_of(mod, "server_side") == 'server' , "shadowed names resolve to locals - no pull";
}

test "native placement is never inferred" {
    mod = compile_fixture("pure_stays_server.jac");
    assert stamp_of(mod, "add") == 'server' , "native-compatible code still defaults to server";
    assert stamp_of(mod, "mul_add") == 'server';
}
