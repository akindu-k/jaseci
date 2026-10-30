"""Probe #10243: a served app's seal precompile against its prepare."""

import os;
import shutil;
import tempfile;
import contextlib;
import from pathlib { Path }
import from jaclang.compiler.driver.application { prepare_application }
import from jaclang.compiler.driver.program { JacProgram }
import from jaclang.runtime.prepared { forget }

test "a served app's seal precompile compiles what its prepare compiled" {
    import from jaclang.compiler.driver.jir { get_module_cache_path }
    import from jaclang.compiler.frontend.codeinfo { effective_default_codespace }
    import from jaclang.dist.precompile_bytecode { precompile_unit_context }
    tmp = tempfile.mkdtemp(prefix='jac-10243-');
    base = Path(tmp);
    path = base / 'main.jac';
    helper = base / 'helper.jac';
    try {
        (base / 'jac.toml').write_text('[project]\nname="sealkeys"\n');
        helper.write_text("def:pub helper -> int { return 2; }\n");
        path.write_text(
            "import from helper { helper }\ndef:pub hello -> int { return helper(); }\n"
        );
        with contextlib.chdir(tmp) {
            prepare_application(str(path), JacProgram(), tmp);
            written = sorted(
                str(p) for p in (base / '.jac' / 'cache').rglob('helper.*.jir')
            );
            with precompile_unit_context(str(helper), tmp) as selected {
                looked = str(get_module_cache_path(str(helper)));
                opts = selected.options;
                print(f"### precompile default_codespace option: {opts.default_codespace!r}");
                print(f"### precompile effective codespace: {effective_default_codespace()!r}");
                print(f"### precompile infers native for helper: {selected.infers_native_codespace(str(helper))}");
                print(f"### precompile module_projection: {opts.module_projection()}");
                codespace = opts.default_codespace or effective_default_codespace();
            }
        }
        print(f"### prepare wrote: {written}");
        print(f"### precompile looks up: {looked}");
        assert codespace == 'server' , f'the seal compiles under {codespace!r}; the prepare under server';
        assert looked in written , f'the precompile looks up {looked}; the prepare wrote {written}';
    } finally {
        forget(str(path));
        shutil.rmtree(tmp, ignore_errors=True);
    }
}
