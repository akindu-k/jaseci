"""Cold-start runtime cache maintenance.

`gc_stale` sweeps the runtime generations the freshly extracted one replaced.
The new generation is published before the sweep runs, so a generation that
refuses to delete costs disk, not correctness, and must not take the process
down with it (issue #9053).

The probe is compiled and JIT-run the way the launcher is: forced into the
native codespace over the fused runtime library staged beside it, exactly as
the desktop builder stages it.
"""

import ctypes;
import os;
import shutil;
import tempfile;
import from pathlib { Path }
import from jaclang.client.targets.desktop.desktop_build { _stage_fused_runtime }
import from jaclang.compiler.driver.compile_options { CompileOptions }
import from jaclang.compiler.driver.program { JacProgram }


glob _CACHE: str = "/tmp/jac_gc_stale_probe",
     _KEEP: str = "1111111111111111-aaaaaaaaaaaaaaaa";


"""Source of a native probe that sweeps the crafted cache once."""
def _probe_source -> str {
    return (
        "import from fused.materialize { gc_stale }\n"
        "\n"
        "def sweep -> int {\n"
        f"    gc_stale(\"{_CACHE}\", \"{_KEEP}\");\n"
        "    return 1;\n"
        "}\n"
    );
}


"""Lay down a runtime generation holding one file."""
def _generation(name: str) -> str {
    full = os.path.join(_CACHE, "rt", name);
    os.makedirs(full, exist_ok=True);
    (open(os.path.join(full, "pinned.py"), "w")).close();
    return full;
}


"""Compile the sweep probe over a staged fused runtime and hand back its entry."""
def _sweep_probe(work: str) -> object {
    _stage_fused_runtime(Path(work));
    probe = os.path.join(work, "gc_probe.jac");
    (Path(probe)).write_text(_probe_source());
    prog = JacProgram();
    opts = CompileOptions(default_codespace="native", force_target_program=True);
    ir = prog.compile(file_path=probe, options=opts);
    assert not prog.errors_had , f"probe failed to compile: {prog.errors_had}";
    eng = ir.gen.native_engine;
    assert eng is not None , "no native engine produced for the sweep probe";
    init_addr = eng.get_function_address("jac_entry");
    if init_addr != 0 {
        ctypes.CFUNCTYPE(None)(init_addr)();
    }
    addr = eng.get_function_address("sweep");
    assert addr != 0 , "sweep not found in the JIT engine";
    return ctypes.CFUNCTYPE(ctypes.c_int64)(addr);
}


test "gc_stale clears replaced generations and survives one it cannot delete" {
    if os.geteuid() == 0 {
        testskip("root ignores the mode bits this test pins the directory with");
    }
    work = tempfile.mkdtemp(prefix="jac_gc_stale_");
    shutil.rmtree(_CACHE, ignore_errors=True);
    pinned = _generation("2222222222222222-aaaaaaaaaaaaaaaa");
    sweepable = _generation("3333333333333333-aaaaaaaaaaaaaaaa");
    other = _generation("2222222222222222-bbbbbbbbbbbbbbbb");
    inflight = _generation("4444444444444444-aaaaaaaaaaaaaaaa.tmp.4242");
    live = _generation(_KEEP);
    os.chmod(pinned, 0o555);
    try {
        sweep = _sweep_probe(work);
        assert sweep() == 1 , "the sweep must return, not abort the process";
        assert os.path.isdir(pinned) , "a generation that will not delete stays put";
        assert not os.path.isdir(sweepable) , (
            "a generation that will delete still goes, whatever the sweep hit"
        );
        assert os.path.isdir(other) , "another binary's generations are not this sweep's";
        assert os.path.isdir(inflight) , "an in-flight extraction is not swept";
        assert os.path.isdir(live) , "the live generation must survive the sweep";
    } finally {
        os.chmod(pinned, 0o755);
        shutil.rmtree(_CACHE, ignore_errors=True);
        shutil.rmtree(work, ignore_errors=True);
    }
}
