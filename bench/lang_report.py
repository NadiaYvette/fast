#!/usr/bin/env python3
"""
Cross-language benchmark: FAST tree FFI vs native data structures.

Auto-detects available compilers/interpreters, compiles benchmark programs,
runs them, and generates a multi-page PDF report comparing FAST FFI
throughput against each language's native search implementations.

Usage:
    python3 bench/lang_report.py [--build-dir build] [--output fast_lang_report.pdf]
                                  [--sizes 65536 524288 4194304] [--queries 5000000]
                                  [--languages c python rust ...]

Prerequisites:
    - The FAST library must be built (libfast.so in build_dir)
    - Python 3 with matplotlib and numpy
"""

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import datetime
from collections import defaultdict
from pathlib import Path

import shutil
import tempfile

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import jinja2


# ── Configuration ─────────────────────────────────────────────────

ROOT = Path(__file__).resolve().parent.parent
LANG_DIR = ROOT / "bench" / "lang"
BINDINGS_DIR = ROOT / "bindings"

DEFAULT_SIZES = [65536, 524288, 2097152, 4194304, 8388608, 16777216, 25165824]
DEFAULT_QUERIES = 5_000_000
SLOW_QUERIES = 500_000
SLOW_LANGUAGES = {"r", "prolog", "mercury", "lisp_clisp"}

# Colors for chart
COLOR_FAST = "#2980b9"
COLOR_NATIVE = "#7f8c8d"
COLOR_SPEEDUP_POS = "#27ae60"
COLOR_SPEEDUP_NEG = "#c0392b"

LANGUAGE_ORDER = [
    "c", "cpp", "rust", "fortran", "ada", "sml", "haskell", "ocaml",
    "java", "go", "julia", "lisp", "scheme", "mercury", "python", "ruby", "r", "prolog",
]

LANGUAGE_LABELS = {
    "c": "C", "cpp": "C++", "rust": "Rust", "python": "Python",
    "java": "Java", "julia": "Julia", "go": "Go", "fortran": "Fortran",
    "ruby": "Ruby", "r": "R", "haskell": "Haskell", "ocaml": "OCaml",
    "lisp": "Common Lisp", "ada": "Ada", "sml": "Standard ML",
    "prolog": "Prolog", "mercury": "Mercury", "scheme": "Scheme",
}


# ── Toolchain Detection ──────────────────────────────────────────

TOOLCHAINS = [
    # (name, command, version_flag, language, label)
    ("gcc",      "gcc",        "--version", "c",       "GCC"),
    ("clang",    "clang",      "--version", "c",       "Clang"),
    ("g++",      "g++",        "--version", "cpp",     "G++"),
    ("clang++",  "clang++",    "--version", "cpp",     "Clang++"),
    ("rustc",    "rustc",      "--version", "rust",    "Rust"),
    ("python3",  "python3",    "--version", "python",  "CPython"),
    ("pypy3",    "pypy3",      "--version", "python",  "PyPy"),
    ("java",     "java",       "--version", "java",    "Java"),
    ("javac",    "javac",      "--version", "java",    "javac"),
    ("julia",    "julia",      "--version", "julia",   "Julia"),
    ("go",       "go",         "version",   "go",      "Go"),
    ("gfortran", "gfortran",   "--version", "fortran", "GFortran"),
    ("ruby",     "ruby",       "--version", "ruby",    "MRI Ruby"),
    ("rscript",  "Rscript",    "--version", "r",       "R"),
    ("ghc",      "ghc",        "--version", "haskell", "GHC"),
    ("ocamlopt", "ocamlfind",  "ocamlopt -version 2>&1 || ocamlopt -version 2>&1", "ocaml", "OCaml"),
    ("sbcl",     "sbcl",       "--version", "lisp",    "SBCL"),
    ("clisp",    "clisp",      "--version", "lisp",    "CLISP"),
    ("gnatmake", "gnatmake",   "--version", "ada",     "GNAT"),
    ("mlton",    "mlton",      "",          "sml",     "MLton"),
    ("swipl",    "swipl",      "--version", "prolog",  "SWI-Prolog"),
    ("mmc",      "mmc",        "--version", "mercury", "Mercury"),
    ("chez",     "scheme",     "--version", "scheme",  "Chez Scheme"),
]

INSTALL_HINTS = {
    "pypy3": "dnf install pypy3 / apt install pypy3",
    "chez": "dnf install chez-scheme / apt install chezscheme",
    "clisp": "dnf install clisp / apt install clisp",
    "flang": "dnf install flang / apt install flang",
}


def extract_version(text):
    """Extract version number from --version output."""
    m = re.search(r"(\d+\.\d+[\.\d]*)", text)
    return m.group(1) if m else "unknown"


def detect_toolchains():
    """Auto-detect available compilers/interpreters."""
    results = {}
    for name, cmd, flag, lang, label in TOOLCHAINS:
        try:
            if name == "ocamlopt":
                # Special case: ocamlfind query
                proc = subprocess.run(
                    ["ocamlopt", "-version"],
                    capture_output=True, text=True, timeout=10
                )
            elif flag:
                proc = subprocess.run(
                    [cmd, flag], capture_output=True, text=True, timeout=10
                )
            else:
                proc = subprocess.run(
                    [cmd], capture_output=True, text=True, timeout=10
                )
            version = extract_version(proc.stdout + proc.stderr)
            results[name] = {
                "available": True, "version": version,
                "language": lang, "label": label, "cmd": cmd,
            }
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            results[name] = {
                "available": False, "version": None,
                "language": lang, "label": label, "cmd": cmd,
            }
    return results


def print_toolchain_summary(tc):
    """Print detected toolchains."""
    available = [(n, t) for n, t in tc.items() if t["available"]]
    missing = [(n, t) for n, t in tc.items() if not t["available"]]

    print(f"  Available ({len(available)}):")
    for name, t in sorted(available):
        print(f"    {t['label']:15s} {t['version']:12s} ({t['language']})")

    if missing:
        print(f"  Not installed ({len(missing)}):")
        for name, t in sorted(missing):
            hint = INSTALL_HINTS.get(name, "")
            extra = f"  [{hint}]" if hint else ""
            print(f"    {t['label']:15s}{extra}")


# ── Compilation ───────────────────────────────────────────────────

def get_compile_rules(root, build_dir, bench_build):
    """Return dict of (lang, compiler) -> {compile, run, env} rules."""
    inc = str(root / "include")
    lib = str(root / build_dir)
    cpp_inc = str(root / "bindings" / "cpp")
    fortran_mod = str(root / "bindings" / "fortran" / "fast_binding.f90")
    haskell_mod = str(root / "bindings" / "haskell" / "Fast.hs")
    ada_dir = str(root / "bindings" / "ada")
    ocaml_stubs = str(root / "bindings" / "ocaml" / "fast_stubs.c")
    rpath = f"-Wl,-rpath,{lib}"
    env_ld = {"LD_LIBRARY_PATH": lib}

    rules = {}

    # C (gcc) — links sqlite3 for B+ tree comparison
    rules[("c", "gcc")] = {
        "compile": ["gcc", "-O3", "-msse2", f"-I{inc}",
                     str(LANG_DIR / "bench_c.c"),
                     f"-L{lib}", "-lfast", "-lsqlite3", rpath,
                     "-o", str(bench_build / "bench_c_gcc")],
        "run": [str(bench_build / "bench_c_gcc"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # C (clang) — links sqlite3 for B+ tree comparison
    rules[("c", "clang")] = {
        "compile": ["clang", "-O3", "-msse2", f"-I{inc}",
                     str(LANG_DIR / "bench_c.c"),
                     f"-L{lib}", "-lfast", "-lsqlite3", rpath,
                     "-o", str(bench_build / "bench_c_clang")],
        "run": [str(bench_build / "bench_c_clang"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # C++ (g++)
    rules[("cpp", "g++")] = {
        "compile": ["g++", "-O3", "-std=c++17", "-msse2",
                     f"-I{inc}", f"-I{cpp_inc}",
                     str(LANG_DIR / "bench_cpp.cpp"),
                     f"-L{lib}", "-lfast", rpath,
                     "-o", str(bench_build / "bench_cpp_gcc")],
        "run": [str(bench_build / "bench_cpp_gcc"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # C++ (clang++)
    rules[("cpp", "clang++")] = {
        "compile": ["clang++", "-O3", "-std=c++17", "-msse2",
                     f"-I{inc}", f"-I{cpp_inc}",
                     str(LANG_DIR / "bench_cpp.cpp"),
                     f"-L{lib}", "-lfast", rpath,
                     "-o", str(bench_build / "bench_cpp_clang")],
        "run": [str(bench_build / "bench_cpp_clang"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Rust
    rules[("rust", "rustc")] = {
        "compile": ["rustc", "-O", "--edition", "2021",
                     f"-L{lib}", "-l", "fast",
                     str(LANG_DIR / "bench_rust.rs"),
                     "-o", str(bench_build / "bench_rust")],
        "run": [str(bench_build / "bench_rust"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Fortran
    rules[("fortran", "gfortran")] = {
        "compile": ["gfortran", "-O3", fortran_mod,
                     str(LANG_DIR / "bench_fortran.f90"),
                     f"-L{lib}", "-lfast", rpath,
                     "-o", str(bench_build / "bench_fortran")],
        "run": [str(bench_build / "bench_fortran"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Haskell (needs clock, vector, containers packages)
    rules[("haskell", "ghc")] = {
        "compile": ["ghc", "-O2", "-no-keep-hi-files", "-no-keep-o-files",
                     "-package", "containers", "-package", "clock",
                     "-package", "vector",
                     str(LANG_DIR / "bench_haskell.hs"), haskell_mod,
                     f"-L{lib}", "-lfast", "-optl", rpath,
                     "-o", str(bench_build / "bench_haskell")],
        "run": [str(bench_build / "bench_haskell"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    ocaml_mod = str(root / "bindings" / "ocaml" / "fast.ml")
    # OCaml (needs fast.ml module + fast_stubs.c from bindings)
    rules[("ocaml", "ocamlopt")] = {
        "compile": ["ocamlfind", "ocamlopt", "-package", "unix", "-linkpkg",
                     ocaml_stubs, ocaml_mod, str(LANG_DIR / "bench_ocaml.ml"),
                     "-cclib", f"-L{lib} -lfast {rpath}",
                     "-ccopt", f"-I{inc}",
                     "-o", str(bench_build / "bench_ocaml")],
        "run": [str(bench_build / "bench_ocaml"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Ada (with Ada.Containers.Ordered_Maps, requires Ada 2012+)
    rules[("ada", "gnatmake")] = {
        "compile": ["gnatmake", "-O3", "-gnat2012", f"-aI{ada_dir}",
                     str(LANG_DIR / "bench_ada.adb"),
                     "-o", str(bench_build / "bench_ada"),
                     "-largs", f"-L{lib}", "-lfast", rpath],
        "run": [str(bench_build / "bench_ada"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # SML (MLton)
    rules[("sml", "mlton")] = {
        "compile": ["mlton", "-output", str(bench_build / "bench_sml"),
                     "-link-opt", f"-L{lib} -lfast {rpath}",
                     str(LANG_DIR / "bench_sml.mlb")],
        "run": [str(bench_build / "bench_sml"), "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Go
    rules[("go", "go")] = {
        "compile": None,  # Go is compiled at run time via go run
        "run": ["go", "run", str(LANG_DIR / "bench_go.go"),
                "{tree_size}", "{num_queries}"],
        "env": {
            "LD_LIBRARY_PATH": lib,
            "CGO_CFLAGS": f"-I{inc}",
            "CGO_LDFLAGS": f"-L{lib} -lfast {rpath}",
        },
    }
    # Java (needs two-step: compile JNI + javac)
    rules[("java", "java")] = {
        "compile": "java_special",  # handled separately
        "run": ["java", "-cp",
                f"{str(root / 'bindings' / 'java')}:{str(LANG_DIR)}",
                f"-Djava.library.path={str(bench_build)}",
                "bench_java", "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Python (CPython)
    rules[("python", "python3")] = {
        "compile": None,
        "run": ["python3", str(LANG_DIR / "bench_python.py"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Python (PyPy)
    rules[("python", "pypy3")] = {
        "compile": None,
        "run": ["pypy3", str(LANG_DIR / "bench_python.py"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Julia
    rules[("julia", "julia")] = {
        "compile": None,
        "run": ["julia", str(LANG_DIR / "bench_julia.jl"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Ruby
    rules[("ruby", "ruby")] = {
        "compile": None,
        "run": ["ruby", str(LANG_DIR / "bench_ruby.rb"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # R
    rules[("r", "rscript")] = {
        "compile": None,
        "run": ["Rscript", str(LANG_DIR / "bench_r.R"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Common Lisp (SBCL)
    rules[("lisp", "sbcl")] = {
        "compile": None,
        "run": ["sbcl", "--noinform", "--non-interactive",
                "--load", str(LANG_DIR / "bench_lisp.lisp")],
        "env": env_ld,
        "args_via_env": True,  # SBCL gets args from command line
    }
    # Common Lisp (CLISP)
    rules[("lisp", "clisp")] = {
        "compile": None,
        "run": ["clisp", str(LANG_DIR / "bench_lisp.lisp"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Prolog
    rules[("prolog", "swipl")] = {
        "compile": None,
        "run": ["swipl", "-g", "main", "-t", "halt",
                str(LANG_DIR / "bench_prolog.pl"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Chez Scheme (binary is 'scheme', not 'chez')
    rules[("scheme", "chez")] = {
        "compile": None,
        "run": ["scheme", "--script",
                str(LANG_DIR / "bench_scheme.ss"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }
    # Mercury (uses tree234 from stdlib; mmc --make requires cwd = source dir)
    rules[("mercury", "mmc")] = {
        "compile": "mercury_special",  # handled separately in compile_mercury()
        "run": [str(bench_build / "bench_mercury"),
                "{tree_size}", "{num_queries}"],
        "env": env_ld,
    }

    return rules


def toolchain_for_rule(lang, compiler, toolchains):
    """Check if the required toolchain is available."""
    # Map rule compiler names to toolchain detection names
    mapping = {
        ("c", "gcc"): "gcc",
        ("c", "clang"): "clang",
        ("cpp", "g++"): "g++",
        ("cpp", "clang++"): "clang++",
        ("rust", "rustc"): "rustc",
        ("python", "python3"): "python3",
        ("python", "pypy3"): "pypy3",
        ("java", "java"): "java",
        ("julia", "julia"): "julia",
        ("go", "go"): "go",
        ("fortran", "gfortran"): "gfortran",
        ("ruby", "ruby"): "ruby",
        ("r", "rscript"): "rscript",
        ("haskell", "ghc"): "ghc",
        ("ocaml", "ocamlopt"): "ocamlopt",
        ("lisp", "sbcl"): "sbcl",
        ("lisp", "clisp"): "clisp",
        ("ada", "gnatmake"): "gnatmake",
        ("sml", "mlton"): "mlton",
        ("prolog", "swipl"): "swipl",
        ("mercury", "mmc"): "mmc",
        ("scheme", "chez"): "chez",
    }
    tc_name = mapping.get((lang, compiler))
    if tc_name and toolchains.get(tc_name, {}).get("available"):
        return True
    return False


def compile_java(root, build_dir, bench_build, toolchains):
    """Special compilation for Java (JNI glue + javac)."""
    java_home = os.environ.get("JAVA_HOME", "")
    if not java_home:
        # Try to detect from java -XshowSettings
        try:
            proc = subprocess.run(
                ["java", "-XshowSettings:property", "-version"],
                capture_output=True, text=True, timeout=10
            )
            for line in (proc.stdout + proc.stderr).splitlines():
                if "java.home" in line:
                    java_home = line.split("=", 1)[1].strip()
                    break
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

    # Fallback: find JNI headers under /usr/lib/jvm
    if not java_home or not Path(java_home, "include", "jni.h").exists():
        import glob
        jni_paths = glob.glob("/usr/lib/jvm/*/include/jni.h")
        if jni_paths:
            java_home = str(Path(jni_paths[0]).parent.parent)

    if not java_home or not Path(java_home, "include", "jni.h").exists():
        print("    SKIPPED: JAVA_HOME not set / no JNI headers", file=sys.stderr)
        return False

    lib = str(root / build_dir)
    inc = str(root / "include")
    jni_src = str(root / "bindings" / "java" / "fast_jni.c")

    # Compile JNI glue
    jni_cmd = [
        "gcc", "-shared", "-fPIC", "-o", str(bench_build / "libfast_jni.so"),
        jni_src,
        f"-I{java_home}/include", f"-I{java_home}/include/linux",
        f"-I{inc}", f"-L{lib}", "-lfast",
    ]
    print(f"    JNI: {' '.join(jni_cmd[:6])}...")
    proc = subprocess.run(jni_cmd, capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        print(f"    JNI compile failed: {proc.stderr[:200]}", file=sys.stderr)
        return False

    # Compile Java benchmark
    javac_cmd = [
        "javac", "-cp",
        f"{str(root / 'bindings' / 'java')}:{str(LANG_DIR)}",
        str(LANG_DIR / "bench_java.java"),
    ]
    print(f"    javac: {' '.join(javac_cmd[:4])}...")
    proc = subprocess.run(javac_cmd, capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        print(f"    javac failed: {proc.stderr[:200]}", file=sys.stderr)
        return False

    return True


def compile_mercury(root, build_dir, bench_build):
    """Special compilation for Mercury (mmc --make from source dir)."""
    lib = str(root / build_dir)
    inc = str(root / "include")

    mmc_cmd = [
        "mmc", "--make", "--grade", "hlc.gc",
        f"--c-include-directory", inc,
        "--ld-flags", f"-L{lib} -lfast -Wl,-rpath,{lib}",
        "bench_mercury",
    ]
    print(f"    mmc: {' '.join(mmc_cmd[:6])}...")
    try:
        proc = subprocess.run(
            mmc_cmd, capture_output=True, text=True, timeout=120,
            cwd=str(LANG_DIR),
        )
        if proc.returncode == 0:
            # Move binary to bench_build
            src = LANG_DIR / "bench_mercury"
            dst = bench_build / "bench_mercury"
            if src.exists():
                import shutil
                shutil.copy2(str(src), str(dst))
                print(" OK")
                return True
            else:
                print(f" FAILED: binary not found at {src}")
                return False
        else:
            print(f" FAILED")
            print(f"    {proc.stderr[:300]}", file=sys.stderr)
            return False
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f" ERROR: {e}")
        return False


def compile_benchmarks(rules, toolchains, root, build_dir, bench_build):
    """Compile all compiled-language benchmarks."""
    compiled = {}

    for (lang, compiler), rule in rules.items():
        if not toolchain_for_rule(lang, compiler, toolchains):
            continue

        if rule.get("compile") is None:
            compiled[(lang, compiler)] = True
            continue

        if rule["compile"] == "java_special":
            print(f"  Compiling java (JNI)...")
            compiled[(lang, compiler)] = compile_java(root, build_dir, bench_build, toolchains)
            continue

        if rule["compile"] == "mercury_special":
            print(f"  Compiling mercury (mmc --make)...")
            compiled[(lang, compiler)] = compile_mercury(
                root, build_dir, bench_build)
            continue

        cmd = rule["compile"]
        label = f"{lang}/{compiler}"
        print(f"  Compiling {label}...", end="", flush=True)
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            if proc.returncode == 0:
                compiled[(lang, compiler)] = True
                print(" OK")
            else:
                compiled[(lang, compiler)] = False
                print(f" FAILED")
                print(f"    {proc.stderr[:300]}", file=sys.stderr)
        except (subprocess.TimeoutExpired, OSError) as e:
            compiled[(lang, compiler)] = False
            print(f" ERROR: {e}")

    return compiled


# ── Execution ─────────────────────────────────────────────────────

def run_benchmarks(rules, compiled, tree_sizes, default_queries, bench_build):
    """Run all benchmarks and collect JSON results."""
    all_results = []
    active = [(k, v) for k, v in compiled.items() if v]
    total = len(active) * len(tree_sizes)
    done = 0

    for (lang, compiler), _ in active:
        rule = rules[(lang, compiler)]

        for size in tree_sizes:
            done += 1
            nq = default_queries
            rule_key = f"{lang}_{compiler}"
            if rule_key in SLOW_LANGUAGES or lang in SLOW_LANGUAGES:
                nq = min(nq, SLOW_QUERIES)

            label = f"{lang}/{compiler} N={size}"
            print(f"  [{done}/{total}] {label}...", end="", flush=True)

            cmd = [s.format(tree_size=size, num_queries=nq) for s in rule["run"]]
            env = dict(os.environ)
            for k, v in rule.get("env", {}).items():
                env[k] = v

            try:
                proc = subprocess.run(
                    cmd, capture_output=True, text=True, timeout=600, env=env,
                    cwd=str(ROOT),
                )
                results_found = False
                for line in proc.stdout.strip().splitlines():
                    line = line.strip()
                    if line.startswith("{"):
                        try:
                            result = json.loads(line)
                            all_results.append(result)
                            results_found = True
                        except json.JSONDecodeError:
                            pass
                if results_found:
                    # Show the last mqs value
                    last = all_results[-1]
                    print(f" {last.get('mqs', '?')} Mq/s")
                else:
                    print(" (no output)")
                    if proc.stderr:
                        print(f"    stderr: {proc.stderr[:200]}", file=sys.stderr)
            except subprocess.TimeoutExpired:
                print(" TIMEOUT")
            except OSError as e:
                print(f" ERROR: {e}")

    return all_results


# ── System Info ───────────────────────────────────────────────────

def get_system_info():
    info = {}
    info["hostname"] = platform.node()
    info["kernel"] = platform.release()
    info["arch"] = platform.machine()
    info["date"] = datetime.datetime.now().isoformat(timespec="seconds")
    info["python"] = platform.python_version()

    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    info["cpu"] = line.split(":", 1)[1].strip()
                    break
    except OSError:
        info["cpu"] = "unknown"

    for name, var in [("L1d", "LEVEL1_DCACHE_SIZE"),
                      ("L2", "LEVEL2_CACHE_SIZE"),
                      ("L3", "LEVEL3_CACHE_SIZE")]:
        try:
            val = subprocess.check_output(
                ["getconf", var], stderr=subprocess.DEVNULL, text=True
            ).strip()
            info[name] = int(val)
        except (subprocess.CalledProcessError, ValueError, FileNotFoundError):
            info[name] = None

    return info


def fmt_bytes(n):
    if n is None:
        return "?"
    if n >= 1_048_576:
        return f"{n // 1_048_576} MB"
    elif n >= 1024:
        return f"{n // 1024} KB"
    return f"{n} B"


def fmt_size(n):
    if n >= 1_000_000:
        return f"{n // 1_000_000}M"
    elif n >= 1_000:
        return f"{n // 1_000}K"
    return str(n)


# ── PDF Report Generation (LaTeX pipeline) ───────────────────────

TEX_SPECIAL = str.maketrans({
    '&': r'\&', '%': r'\%', '$': r'\$', '#': r'\#',
    '_': r'\_', '{': r'\{', '}': r'\}', '~': r'\textasciitilde{}',
    '^': r'\textasciicircum{}',
})


def tex_escape(s):
    """Escape LaTeX special characters in a string."""
    if not isinstance(s, str):
        s = str(s)
    return s.translate(TEX_SPECIAL)


def _make_sweep_chart(build_dir, out_path):
    """Run a dense C-level FAST vs bsearch sweep and save chart to out_path."""
    bench_perf = (Path(build_dir) / "fast_bench_perf").resolve()
    if not bench_perf.exists():
        return

    sweep_sizes = [256, 1024, 4096, 16384, 65536, 131072, 262144,
                   524288, 1048576, 2097152, 4194304, 8388608,
                   16777216, 25165824]
    fast_ns = []
    bsearch_ns = []
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(Path(build_dir).resolve())

    print("  Running dense C sweep for report...", flush=True)
    for sz in sweep_sizes:
        nq = min(2_000_000, max(500_000, 10_000_000 // max(sz, 1)))
        try:
            proc = subprocess.run(
                [str(bench_perf), "all", str(sz), str(nq)],
                capture_output=True, text=True, timeout=120, env=env,
                cwd=str(Path(build_dir).resolve()),
            )
            f_ns = b_ns = None
            for line in proc.stdout.splitlines():
                if "fast-tree" in line:
                    m = re.search(r"([\d.]+)\s+ns/query", line)
                    if m:
                        f_ns = float(m.group(1))
                elif "sorted-array-bsearch" in line:
                    m = re.search(r"([\d.]+)\s+ns/query", line)
                    if m:
                        b_ns = float(m.group(1))
            fast_ns.append(f_ns)
            bsearch_ns.append(b_ns)
        except (subprocess.TimeoutExpired, OSError):
            fast_ns.append(None)
            bsearch_ns.append(None)

    # Filter out failures
    valid = [(s, f, b) for s, f, b in zip(sweep_sizes, fast_ns, bsearch_ns)
             if f is not None and b is not None]
    if len(valid) < 3:
        return

    sizes_v, fast_v, bsearch_v = zip(*valid)
    speedups = [b / f for f, b in zip(fast_v, bsearch_v)]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 8.5))
    fig.suptitle("FAST vs Binary Search: Dense Tree-Size Sweep (C)",
                 fontsize=14, fontweight="bold")

    # Top: ns/query
    ax1.plot(range(len(sizes_v)), fast_v, "o-", color=COLOR_FAST,
             label="FAST tree", linewidth=2, markersize=5)
    ax1.plot(range(len(sizes_v)), bsearch_v, "s--", color=COLOR_NATIVE,
             label="Binary search", linewidth=2, markersize=5)
    ax1.set_xticks(range(len(sizes_v)))
    ax1.set_xticklabels([fmt_size(s) for s in sizes_v], fontsize=7)
    ax1.set_ylabel("ns/query", fontsize=11)
    ax1.set_xlabel("Tree size (keys)", fontsize=10)
    ax1.legend(fontsize=9)
    ax1.grid(alpha=0.3)
    ax1.set_axisbelow(True)

    # Shade cache regions
    l2_bytes = 1_310_720  # 1.25 MiB
    l3_bytes = 25_165_824  # 24 MiB
    for ax in [ax1, ax2]:
        for i, s in enumerate(sizes_v):
            key_bytes = s * 4
            if key_bytes <= l2_bytes:
                ax.axvspan(i - 0.5, i + 0.5, alpha=0.06, color="green")
            elif key_bytes <= l3_bytes:
                ax.axvspan(i - 0.5, i + 0.5, alpha=0.06, color="orange")
            else:
                ax.axvspan(i - 0.5, i + 0.5, alpha=0.06, color="red")

    # Bottom: speedup
    colors = [COLOR_SPEEDUP_POS if s >= 1.0 else COLOR_SPEEDUP_NEG
              for s in speedups]
    ax2.bar(range(len(sizes_v)), speedups, color=colors, zorder=3)
    ax2.axhline(y=1.0, color="black", linestyle="--", linewidth=1, zorder=2)
    ax2.set_xticks(range(len(sizes_v)))
    ax2.set_xticklabels([fmt_size(s) for s in sizes_v], fontsize=7)
    ax2.set_ylabel("Speedup (bsearch / FAST)", fontsize=11)
    ax2.set_xlabel("Tree size (keys)    [green=L2, orange=L3, red=beyond L3]",
                   fontsize=9)
    ax2.grid(axis="y", alpha=0.3, zorder=0)
    ax2.set_axisbelow(True)
    for i, sp in enumerate(speedups):
        ax2.text(i, sp + 0.02, f"{sp:.2f}x", ha="center", va="bottom",
                 fontsize=6, fontweight="bold")

    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(out_path, format="pdf", bbox_inches="tight")
    plt.close(fig)


# ── Chart generation helpers ──────────────────────────────────────

def _make_bar_chart(results, tree_sizes, out_path):
    """Generate FAST FFI vs Native bar chart, save to out_path."""
    by_lang = defaultdict(list)
    for r in results:
        by_lang[r["language"]].append(r)

    target_size = max(tree_sizes)
    lang_data = {}
    for lang, recs in by_lang.items():
        target_recs = [r for r in recs if r["tree_size"] == target_size]
        if not target_recs:
            sizes = set(r["tree_size"] for r in recs)
            if sizes:
                ts = max(sizes)
                target_recs = [r for r in recs if r["tree_size"] == ts]
        fast_recs = [r for r in target_recs if r["method"] == "fast_ffi"]
        native_recs = [r for r in target_recs if r["method"] != "fast_ffi"]
        if fast_recs and native_recs:
            best_fast = max(fast_recs, key=lambda r: r.get("mqs", 0))
            best_native = max(native_recs, key=lambda r: r.get("mqs", 0))
            lang_data[lang] = {
                "fast_mqs": best_fast.get("mqs", 0),
                "native_mqs": best_native.get("mqs", 0),
            }

    if not lang_data:
        return False

    sorted_langs = sorted(lang_data.keys(),
                          key=lambda l: lang_data[l]["fast_mqs"],
                          reverse=True)

    fig = plt.figure(figsize=(11, 6))
    ax = fig.add_subplot(111)
    x = np.arange(len(sorted_langs))
    width = 0.35

    fast_vals = [lang_data[l]["fast_mqs"] for l in sorted_langs]
    native_vals = [lang_data[l]["native_mqs"] for l in sorted_langs]

    ax.bar(x - width/2, fast_vals, width, label="FAST FFI",
           color=COLOR_FAST, zorder=3)
    ax.bar(x + width/2, native_vals, width, label="Native",
           color=COLOR_NATIVE, zorder=3)

    labels = [LANGUAGE_LABELS.get(l, l) for l in sorted_langs]
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=9)
    ax.set_ylabel("Throughput (Mqueries/s)", fontsize=11)
    max_mb = target_size * 4 / (1024 * 1024)
    ax.set_title(f"FAST FFI vs Native Search — {fmt_size(target_size)} keys "
                 f"({max_mb:.0f} MB)", fontsize=14, fontweight="bold")
    ax.legend(fontsize=10)
    ax.set_yscale("log")
    ax.grid(axis="y", alpha=0.3, zorder=0)
    ax.set_axisbelow(True)

    fig.tight_layout()
    fig.savefig(out_path, format="pdf", bbox_inches="tight")
    plt.close(fig)
    return True


def _make_speedup_chart(results, tree_sizes, out_path):
    """Generate speedup ratio chart, save to out_path."""
    by_lang = defaultdict(list)
    for r in results:
        by_lang[r["language"]].append(r)

    target_size = max(tree_sizes)
    speedup_data = {}
    for lang, recs in by_lang.items():
        target_recs = [r for r in recs if r["tree_size"] == target_size]
        if not target_recs:
            sizes = set(r["tree_size"] for r in recs)
            if sizes:
                ts = max(sizes)
                target_recs = [r for r in recs if r["tree_size"] == ts]
        fast_recs = [r for r in target_recs if r["method"] == "fast_ffi"]
        native_recs = [r for r in target_recs if r["method"] != "fast_ffi"]
        if fast_recs and native_recs:
            best_fast = max(fast_recs, key=lambda r: r.get("mqs", 0))
            best_native = max(native_recs, key=lambda r: r.get("mqs", 0))
            if best_native.get("mqs", 0) > 0:
                speedup_data[lang] = best_fast["mqs"] / best_native["mqs"]

    if not speedup_data:
        return False

    sorted_langs = sorted(speedup_data.keys(),
                          key=lambda l: speedup_data[l], reverse=True)
    vals = [speedup_data[l] for l in sorted_langs]
    colors = [COLOR_SPEEDUP_POS if v >= 1.0 else COLOR_SPEEDUP_NEG
              for v in vals]

    fig = plt.figure(figsize=(11, 5))
    ax = fig.add_subplot(111)
    x = np.arange(len(sorted_langs))
    ax.bar(x, vals, color=colors, zorder=3)
    ax.axhline(y=1.0, color="black", linestyle="--", linewidth=1, zorder=2)

    labels = [LANGUAGE_LABELS.get(l, l) for l in sorted_langs]
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=9)
    ax.set_ylabel("Speedup (FAST / Native)", fontsize=11)
    ax.set_title(f"FAST FFI Speedup Over Native — {fmt_size(max(tree_sizes))} keys",
                 fontsize=14, fontweight="bold")
    ax.set_yscale("log")
    ax.grid(axis="y", alpha=0.3, zorder=0)
    ax.set_axisbelow(True)
    for i, sp in enumerate(vals):
        ax.text(i, sp * 1.03, f"{sp:.1f}x", ha="center", va="bottom",
                fontsize=7, fontweight="bold")

    fig.tight_layout()
    fig.savefig(out_path, format="pdf", bbox_inches="tight")
    plt.close(fig)
    return True


def _make_grid_chart(results, out_path):
    """Generate per-language throughput grid chart, save to out_path."""
    by_lang = defaultdict(list)
    for r in results:
        by_lang[r["language"]].append(r)

    langs_ordered = [l for l in LANGUAGE_ORDER if l in by_lang]
    langs_with_data = [l for l in langs_ordered
                       if any(r.get("mqs", 0) > 0 for r in by_lang[l])]
    if not langs_with_data:
        return False

    n_langs = len(langs_with_data)
    cols = 4
    rows = (n_langs + cols - 1) // cols

    fig, axes = plt.subplots(rows, cols, figsize=(11, 2.5 * rows))
    fig.suptitle("Per-Language Throughput vs Tree Size",
                 fontsize=14, fontweight="bold", y=1.0)
    if rows == 1:
        axes = axes.reshape(1, -1)

    method_colors = {}
    color_cycle = ["#e74c3c", "#27ae60", "#8e44ad", "#f39c12"]
    ci = [0]

    def get_method_color(method):
        if method == "fast_ffi":
            return COLOR_FAST
        if method not in method_colors:
            method_colors[method] = color_cycle[ci[0] % len(color_cycle)]
            ci[0] += 1
        return method_colors[method]

    # Build a global x-axis from all sizes present across all languages.
    all_sizes = sorted(set(r["tree_size"] for r in results if r.get("mqs", 0) > 0))
    size_to_idx = {s: i for i, s in enumerate(all_sizes)}
    n_ticks = len(all_sizes)

    for idx, lang in enumerate(langs_with_data):
        r, c = divmod(idx, cols)
        ax = axes[r, c]
        recs = by_lang[lang]
        methods = set(r_["method"] for r_ in recs)
        for method in sorted(methods):
            method_recs = [r_ for r_ in recs if r_["method"] == method]
            # Aggregate per size: take best (max) throughput across compilers
            best_by_size = {}
            for r_ in method_recs:
                sz = r_["tree_size"]
                mq = r_.get("mqs", 0)
                if mq > 0 and (sz not in best_by_size or mq > best_by_size[sz]):
                    best_by_size[sz] = mq
            if not best_by_size:
                continue
            sorted_sizes = sorted(best_by_size.keys())
            x_pos = [size_to_idx[s] for s in sorted_sizes]
            mqs = [best_by_size[s] for s in sorted_sizes]
            color = get_method_color(method)
            ls = "-" if method == "fast_ffi" else "--"
            ax.plot(x_pos, mqs, f"o{ls}", color=color,
                    label=method, markersize=4, linewidth=1.5)
        ax.set_xlim(-0.3, n_ticks - 0.7)
        ax.set_xticks(range(n_ticks))
        ax.set_xticklabels([fmt_size(s) for s in all_sizes], fontsize=6)
        ax.set_title(LANGUAGE_LABELS.get(lang, lang), fontsize=9,
                     fontweight="bold")
        ax.set_ylabel("Mq/s", fontsize=7)
        ax.legend(fontsize=5, loc="best")
        ax.grid(alpha=0.3)
        ax.set_axisbelow(True)

    for idx in range(n_langs, rows * cols):
        r, c = divmod(idx, cols)
        axes[r, c].set_visible(False)

    fig.tight_layout()
    fig.savefig(out_path, format="pdf", bbox_inches="tight")
    plt.close(fig)
    return True


def _make_compiler_chart(results, lang, tree_sizes, out_path):
    """Generate compiler comparison chart for one language, save to out_path."""
    target_size = max(tree_sizes)
    lang_recs = [r for r in results if r.get("language") == lang]
    compilers = sorted(set(r.get("compiler", "") for r in lang_recs))
    if len(compilers) < 2:
        return False

    methods = sorted(set(r.get("method", "") for r in lang_recs))
    x_pos = np.arange(len(methods))
    n_compilers = len(compilers)
    width = 0.8 / n_compilers

    fig = plt.figure(figsize=(11, 5))
    ax = fig.add_subplot(111)
    colors_list = ["#2980b9", "#e74c3c", "#27ae60", "#8e44ad"]

    for ci, comp in enumerate(compilers):
        vals = []
        for method in methods:
            mrecs = [r for r in lang_recs
                     if r.get("compiler") == comp
                     and r.get("method") == method
                     and r.get("tree_size") == target_size]
            vals.append(mrecs[0].get("mqs", 0) if mrecs else 0)
        ax.bar(x_pos + ci * width, vals, width, label=comp,
               color=colors_list[ci % len(colors_list)])

    ax.set_xticks(x_pos + width * (n_compilers - 1) / 2)
    ax.set_xticklabels(methods, fontsize=9)
    ax.set_ylabel("Throughput (Mq/s)", fontsize=11)
    ax.set_title(f"Compiler Comparison: {LANGUAGE_LABELS.get(lang, lang)} "
                 f"— {fmt_size(target_size)} keys",
                 fontsize=14, fontweight="bold")
    ax.legend(fontsize=9)
    ax.grid(axis="y", alpha=0.3)
    ax.set_axisbelow(True)

    fig.tight_layout()
    fig.savefig(out_path, format="pdf", bbox_inches="tight")
    plt.close(fig)
    return True


# ── LaTeX rendering and compilation ──────────────────────────────

def save_charts(results, sys_info, tree_sizes, build_dir, chart_dir):
    """Generate all charts as individual PDF files. Returns dict of paths."""
    chart_dir = Path(chart_dir)
    chart_dir.mkdir(parents=True, exist_ok=True)
    charts = {}

    bar_path = chart_dir / "chart_bar.pdf"
    if _make_bar_chart(results, tree_sizes, bar_path):
        charts["bar"] = str(bar_path)

    speedup_path = chart_dir / "chart_speedup.pdf"
    if _make_speedup_chart(results, tree_sizes, speedup_path):
        charts["speedup"] = str(speedup_path)

    grid_path = chart_dir / "chart_grid.pdf"
    if _make_grid_chart(results, grid_path):
        charts["grid"] = str(grid_path)

    sweep_path = chart_dir / "chart_sweep.pdf"
    _make_sweep_chart(build_dir, sweep_path)
    if sweep_path.exists():
        charts["sweep"] = str(sweep_path)

    # Compiler comparison charts
    compiler_groups = defaultdict(list)
    for r in results:
        key = (r.get("language", ""), r.get("tree_size", 0), r.get("method", ""))
        compiler_groups[key].append(r)

    multi_compiler_langs = set()
    for (lang, size, method), recs in compiler_groups.items():
        compilers = set(r.get("compiler", "") for r in recs)
        if len(compilers) > 1:
            multi_compiler_langs.add(lang)

    charts["compilers"] = {}
    for lang in sorted(multi_compiler_langs):
        comp_path = chart_dir / f"chart_compiler_{lang}.pdf"
        if _make_compiler_chart(results, lang, tree_sizes, comp_path):
            charts["compilers"][lang] = str(comp_path)

    return charts


def render_latex(results, sys_info, toolchains, tree_sizes, charts, build_dir):
    """Render the LaTeX template with benchmark data. Returns .tex string."""
    template_path = Path(__file__).parent / "report_template.tex.j2"

    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(template_path.parent)),
        block_start_string=r'\BLOCK{',
        block_end_string='}',
        variable_start_string=r'\VAR{',
        variable_end_string='}',
        comment_start_string=r'\#{',
        comment_end_string='}',
        line_statement_prefix='%%>',
        line_comment_prefix='%%#',
        trim_blocks=True,
        lstrip_blocks=True,
        autoescape=False,
    )
    template = env.get_template(template_path.name)

    # Build toolchain list for template
    tc_list = []
    for name, info in sorted(toolchains.items()):
        if info.get("available"):
            tc_list.append({
                "label": tex_escape(info.get("label", name)),
                "version": tex_escape(info.get("version", "unknown")),
                "language": tex_escape(info.get("language", "")),
            })

    # Build results table rows
    results_table = []
    for r in sorted(results,
                    key=lambda x: (x.get("language", ""),
                                   x.get("method", ""),
                                   x.get("tree_size", 0))):
        results_table.append({
            "language": tex_escape(
                LANGUAGE_LABELS.get(r.get("language", ""),
                                    r.get("language", ""))),
            "compiler": tex_escape(r.get("compiler", "")),
            "method": tex_escape(r.get("method", "")),
            "tree_size": fmt_size(r.get("tree_size", 0)),
            "mqs": f"{r.get('mqs', 0):.2f}",
            "ns_per_query": f"{r.get('ns_per_query', 0):.1f}",
            "is_fast": r.get("method", "") == "fast_ffi",
        })

    # Build compiler charts list
    compiler_charts = []
    for lang in sorted(charts.get("compilers", {}).keys()):
        compiler_charts.append({
            "label": tex_escape(LANGUAGE_LABELS.get(lang, lang)),
            "path": Path(charts["compilers"][lang]).name,
        })

    target_size = max(tree_sizes)
    max_mb = target_size * 4 / (1024 * 1024)

    context = {
        "sys_info": {
            "cpu": tex_escape(sys_info.get("cpu", "unknown")),
            "kernel": tex_escape(sys_info.get("kernel", "unknown")),
            "date": tex_escape(sys_info.get("date", "")),
        },
        "l1d": fmt_bytes(sys_info.get("L1d")),
        "l2": fmt_bytes(sys_info.get("L2")),
        "l3": fmt_bytes(sys_info.get("L3")),
        "tree_sizes_str": ", ".join(fmt_size(s) for s in tree_sizes),
        "max_size_label": fmt_size(target_size),
        "max_size_mb": (f"{max_mb:.0f}\\,MB" if max_mb >= 1
                        else f"{target_size * 4 / 1024:.0f}\\,KB"),
        "toolchains": tc_list,
        "chart_bar": Path(charts["bar"]).name if "bar" in charts else "",
        "chart_speedup": Path(charts["speedup"]).name if "speedup" in charts else "",
        "chart_grid": Path(charts["grid"]).name if "grid" in charts else "",
        "chart_sweep": Path(charts["sweep"]).name if "sweep" in charts else "",
        "results_table": results_table,
        "compiler_charts": compiler_charts,
    }

    return template.render(**context)


def compile_latex(tex_content, output_path, chart_dir):
    """Compile a .tex string to PDF using pdflatex."""
    with tempfile.TemporaryDirectory() as tmpdir:
        tex_path = Path(tmpdir) / "report.tex"
        tex_path.write_text(tex_content, encoding="utf-8")

        # Symlink chart PDFs into the temp directory so \includegraphics finds them
        chart_dir = Path(chart_dir)
        if chart_dir.exists():
            for pdf_file in chart_dir.glob("*.pdf"):
                dst = Path(tmpdir) / pdf_file.name
                if not dst.exists():
                    os.symlink(pdf_file.resolve(), dst)

        # Run pdflatex twice (first pass for ToC, second for references)
        for pass_num in range(2):
            proc = subprocess.run(
                ["pdflatex", "-interaction=nonstopmode",
                 "-halt-on-error", "report.tex"],
                cwd=tmpdir, capture_output=True, text=True, timeout=120,
            )
            if proc.returncode != 0 and pass_num == 1:
                print("  pdflatex warnings/errors (pass 2):")
                # Show last 30 lines of log for debugging
                for line in proc.stdout.splitlines()[-30:]:
                    print(f"    {line}")

        result_pdf = Path(tmpdir) / "report.pdf"
        if result_pdf.exists():
            shutil.copy2(result_pdf, output_path)
        else:
            print("Error: pdflatex did not produce output PDF.")
            print("Full pdflatex log:")
            log_path = Path(tmpdir) / "report.log"
            if log_path.exists():
                print(log_path.read_text()[-3000:])


def generate_report(results, sys_info, toolchains, tree_sizes, output_path,
                    build_dir="build"):
    """Generate a LaTeX-typeset PDF report."""
    if not results:
        print("No results to report.")
        return

    chart_dir = Path(build_dir) / "report_charts"
    print("  Generating charts...", flush=True)
    charts = save_charts(results, sys_info, tree_sizes, build_dir, chart_dir)
    print("  Rendering LaTeX...", flush=True)
    tex = render_latex(results, sys_info, toolchains, tree_sizes, charts,
                       build_dir)
    print("  Compiling PDF (2 passes)...", flush=True)
    compile_latex(tex, output_path, chart_dir)


# ── Main ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="FAST cross-language benchmark report generator")
    parser.add_argument("--build-dir", default="build",
                        help="CMake build directory (default: build)")
    parser.add_argument("--output", default="fast_lang_report.pdf",
                        help="Output PDF path (default: fast_lang_report.pdf)")
    parser.add_argument("--sizes", nargs="+", type=int,
                        default=DEFAULT_SIZES,
                        help="Tree sizes to test")
    parser.add_argument("--queries", type=int, default=DEFAULT_QUERIES,
                        help="Number of queries per test")
    parser.add_argument("--languages", nargs="+", default=None,
                        help="Specific languages to test (default: all available)")
    args = parser.parse_args()

    # Verify libfast exists
    libfast = ROOT / args.build_dir / "libfast.so"
    if not libfast.exists():
        print(f"Error: {libfast} not found. Build the project first:")
        print(f"  cmake -B {args.build_dir} && cmake --build {args.build_dir}")
        sys.exit(1)

    print("FAST Cross-Language Benchmark Report")
    print("=" * 40)

    # 1. Detect toolchains
    print("\nDetecting toolchains...")
    toolchains = detect_toolchains()
    print_toolchain_summary(toolchains)

    # 2. Get compile/run rules
    bench_build = ROOT / args.build_dir / "lang_bench"
    bench_build.mkdir(parents=True, exist_ok=True)
    rules = get_compile_rules(ROOT, args.build_dir, bench_build)

    # 3. Filter by requested languages
    if args.languages:
        rules = {(l, c): r for (l, c), r in rules.items()
                 if l in args.languages}

    # 4. Compile
    print("\nCompiling benchmarks...")
    compiled = compile_benchmarks(rules, toolchains, ROOT, args.build_dir, bench_build)

    n_ready = sum(1 for v in compiled.values() if v)
    print(f"\n{n_ready} benchmark configurations ready")

    # 5. Run
    print(f"\nRunning benchmarks ({len(args.sizes)} sizes)...\n")
    results = run_benchmarks(rules, compiled, args.sizes, args.queries, bench_build)

    print(f"\nCollected {len(results)} result entries")

    # 6. Generate report
    sys_info = get_system_info()
    print(f"\nGenerating report: {args.output}")
    generate_report(results, sys_info, toolchains, args.sizes, args.output,
                    build_dir=args.build_dir)
    print(f"Done. Report saved to {args.output}")


if __name__ == "__main__":
    main()
