#!/usr/bin/env bash
#
# mayhem/build.sh — build the rfc3986 Atheris fuzz harness + its standalone reproducer,
# and prepare the project's own pytest suite. Runs inside the commit image (mayhem/Dockerfile)
# as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + the test deps + rfc3986 itself OFFLINE from that wheelhouse into a
#      fixed site dir on PYTHONPATH. The first (CI, online) build fills the wheelhouse; the
#      air-gapped PATCH re-run resolves entirely from it (pip --no-index --find-links).
#   2. Compile launcher.c -> the ELF Mayhem target `rfc3986_fuzzer` (Atheris is a Python
#      script; Mayhem needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper).
#   3. Build the same launcher as the standalone (run-once) reproducer `rfc3986_fuzzer-standalone`.
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). We only need
# DEBUG_FLAGS here (the launcher is a thin C exec wrapper — sanitizing it would just instrument the
# wrapper, not the fuzzed Python; Atheris instruments the Python library itself at import time).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"
PYVER="$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"

# 1) Wheelhouse: download every runtime/test dependency ONCE (online). On the air-gapped re-run the
#    directory is already populated, so pip never reaches the network. atheris ships a prebuilt
#    manylinux wheel for this CPython, so no compilation is needed. idna powers the idna2008 tests;
#    attrs is a rfc3986 test dep; pytest is the suite runner.
PKGS=(atheris pytest pytest-cov idna "attrs")
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). This is guarded to be
#    idempotent: once the site dir holds atheris+pytest we SKIP the reinstall — re-running a
#    `pip install --target --upgrade` over an already-populated target is both wasteful and (under
#    qemu) flaky. rfc3986 itself stays the editable source tree (added to PYTHONPATH below) so a
#    PATCH agent's edits under src/rfc3986 take effect with no reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','pytest*'))) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi
# rfc3986 itself: keep it as the editable source tree (so a PATCH agent's edits under src/rfc3986
# take effect immediately). We expose it by putting $SRC/src on PYTHONPATH — both via the baked ENV
# in the Dockerfile (run time) and via env.sh / the explicit sanity check below (build time). A
# `.pth` in a --target dir is NOT processed (only real site dirs run .pth), so PYTHONPATH is the
# robust, idempotent mechanism here.
PYRUN="$SITE:$SRC/src"

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, rfc3986, pytest; print("imports OK:", rfc3986.__version__)'

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits
#    at run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + rfc3986.
HARNESS="$SRC/mayhem/fuzz_rfc3986.py"
echo ">> compiling rfc3986_fuzzer (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/rfc3986_fuzzer"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when the
# harness is given a file path (no fuzzing loop), which is exactly the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/rfc3986_fuzzer-standalone"

# 4) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's anti-reward-hack
#    sabotage check (which neuters non-system binaries to exit(0)) actually bites the suite — a
#    test.sh that shelled straight to the /usr/bin python would be spared and look reward-hackable.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/rfc3986_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/rfc3986_fuzzer" "$SRC/rfc3986_fuzzer-standalone" "$SRC/rfc3986_run_tests"
