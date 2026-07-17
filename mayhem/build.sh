#!/usr/bin/env bash
# libcbor/mayhem/build.sh — build (a) libcbor itself + the cbor_load_fuzzer libFuzzer harness (the
# Mayhem target `cbor_load_fuzzer`) with $SANITIZER_FLAGS so the FUZZED parser is instrumented, plus
# a standalone (non-fuzzer) reproducer; and (b) libcbor's OWN cmocka unit-test suite with NORMAL
# flags so mayhem/test.sh only RUNS it (an honest PATCH oracle, never compiles).
#
# Adapted from upstream oss-fuzz/build.sh: that script CMake-builds libcbor (SANITIZE=OFF, since the
# fuzzing engine supplies the sanitizers via CFLAGS), then links oss-fuzz/cbor_load_fuzzer.cc against
# the resulting static src/libcbor.a + $LIB_FUZZING_ENGINE. We do the same, instrumenting the library
# build with $SANITIZER_FLAGS so cbor_load (the fuzzed parser) is sanitized, and add the standalone
# repro + the cmocka test build. The harness reads a raw CBOR byte stream via cbor_load() and then
# exercises cbor_describe / cbor_serialize_alloc / cbor_copy on any successfully-decoded item.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

WORK="${WORK:-/tmp/libcbor-work}"
rm -rf "$WORK"; mkdir -p "$WORK"

# ── 1) Sanitized libcbor + fuzz target ───────────────────────────────────────────
# Build libcbor as a static lib instrumented WITH $SANITIZER_FLAGS (so the fuzzed parser, cbor_load,
# is sanitized). SANITIZE=OFF disables libcbor's *own* sanitizer wiring — we inject ours via flags.
# CMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF keeps the static .a linkable into the harness (matches oss-fuzz).
SAN_BUILD="$WORK/oss_fuzz_build"
rm -rf "$SAN_BUILD"; mkdir -p "$SAN_BUILD"
cmake -S "$SRC" -B "$SAN_BUILD" \
    -D CMAKE_BUILD_TYPE=Debug \
    -D CMAKE_INSTALL_PREFIX="$WORK" \
    -D SANITIZE=OFF \
    -D CMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -D WITH_EXAMPLES=OFF \
    -D BUILD_SHARED_LIBS=OFF \
    -D CMAKE_C_COMPILER="$CC" \
    -D CMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
make -C "$SAN_BUILD" "-j$MAYHEM_JOBS"
make -C "$SAN_BUILD" install   # populates $WORK/include (incl. generated cbor/configuration.h) + lib

LIBCBOR_A="$SAN_BUILD/src/libcbor.a"
[ -f "$LIBCBOR_A" ] || { echo "build.sh: $LIBCBOR_A not produced" >&2; exit 1; }

# 1a) libFuzzer harness (the Mayhem target `cbor_load_fuzzer`).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 "-I$WORK/include" \
    "$SRC/mayhem/cbor_load_fuzzer.cc" $LIB_FUZZING_ENGINE "$LIBCBOR_A" \
    -o /mayhem/cbor_load_fuzzer

# 1b) Standalone (non-fuzzer) reproducer: same harness + LLVM's run-once driver. The harness is C++,
#     so compile $STANDALONE_FUZZ_MAIN as a C object first (clang++ would mangle its
#     LLVMFuzzerTestOneInput reference). Respects $SANITIZER_FLAGS.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 "-I$WORK/include" \
    "$SRC/mayhem/cbor_load_fuzzer.cc" /tmp/standalone_main.o "$LIBCBOR_A" \
    -o /mayhem/cbor_load_fuzzer-standalone

# ── 2) libcbor's OWN cmocka unit-test suite (NORMAL flags, no sanitizers) ─────────────────────────
# A separate, clean, sanitizer-free CMake build with WITH_TESTS=ON. Each test/*_test.c is a cmocka
# program asserting libcbor's decode/encode BEHAVIOR (exact decoded values, round-trips, error codes)
# and aborts on mismatch — so a no-op/exit(0) "patch" makes the asserts wrong and the suite fails.
# build.sh compiles it here so mayhem/test.sh only RUNS ctest (an honest PATCH oracle). Requires
# libcmocka-dev (installed via the Dockerfile USER root apt step).
TEST_BUILD="$SRC/mayhem-test-build"
rm -rf "$TEST_BUILD"; mkdir -p "$TEST_BUILD"
echo "build.sh: building libcbor cmocka test suite (normal flags)"
cmake -S "$SRC" -B "$TEST_BUILD" \
    -D CMAKE_BUILD_TYPE=Debug \
    -D WITH_TESTS=ON \
    -D SANITIZE=OFF \
    -D WITH_EXAMPLES=OFF \
    -D CMAKE_C_COMPILER="$CC" \
    >/tmp/libcbor-test-cmake.log 2>&1 || {
  echo "build.sh: test-suite cmake config failed:" >&2; tail -40 /tmp/libcbor-test-cmake.log >&2; exit 1; }
make -C "$TEST_BUILD" "-j$MAYHEM_JOBS" \
    >/tmp/libcbor-test-build.log 2>&1 || {
  echo "build.sh: test-suite build failed:" >&2; tail -60 /tmp/libcbor-test-build.log >&2; exit 1; }

# Sanity: confirm the suite produced its ctest registry.
[ -f "$TEST_BUILD/CTestTestfile.cmake" ] || ls "$TEST_BUILD"/test/CTestTestfile.cmake >/dev/null 2>&1 || {
  echo "build.sh: no CTest registry produced — test build is broken" >&2; exit 1; }

echo "build.sh: built /mayhem/cbor_load_fuzzer (+ -standalone) and the libcbor cmocka test suite"
ls -l /mayhem/cbor_load_fuzzer /mayhem/cbor_load_fuzzer-standalone
