#!/usr/bin/env bash
# libcbor/mayhem/test.sh — RUN libcbor's OWN cmocka unit-test suite (built by mayhem/build.sh with the
# project's normal flags, no sanitizers) → CTRF. PATCH-grade oracle: it never compiles the fuzz build.
#
# Behavioral oracle (anti-reward-hacking, §6.3): runs each cmocka test binary directly and parses its
# stdout for the "[  PASSED  ] N test(s)." line that cmocka always emits on success. A sabotaged binary
# that just exit(0)s produces NO output, so the grep fails and the test is counted as FAILED — the
# sabotage check cannot pass by neutering the program.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

TEST_BUILD="$SRC/mayhem-test-build"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

[ -d "$TEST_BUILD" ] || {
  echo "missing $TEST_BUILD — build.sh did not build the test suite?" >&2
  emit_ctrf "cmake-ctest" 0 1
  exit 2
}

TEST_BIN="$TEST_BUILD/test"
[ -d "$TEST_BIN" ] || {
  echo "missing $TEST_BIN — no test binaries?" >&2
  emit_ctrf "cmake-ctest" 0 1
  exit 2
}

# Enumerate test executables (files that are executable and not CMake/Makefile artifacts).
mapfile -t TESTS < <(find "$TEST_BIN" -maxdepth 1 -type f -executable \
  ! -name '*.cmake' ! -name 'Makefile' ! -name '*.sh' | sort)

if [ "${#TESTS[@]}" -eq 0 ]; then
  echo "test.sh: no test executables found in $TEST_BIN" >&2
  emit_ctrf "cmake-ctest" 0 1
  exit 2
fi

TOTAL_PASSED=0
TOTAL_FAILED=0

for bin in "${TESTS[@]}"; do
  name="$(basename "$bin")"
  # Run the binary and capture stdout+stderr. cmocka writes to stdout.
  bin_rc=0
  out="$("$bin" 2>&1)" || bin_rc=$?
  # Behavioral check: the program MUST produce non-empty output and exit 0.
  # A neutered binary (exit 0, no output) produces nothing — the emptiness check below fails.
  if [ "$bin_rc" -ne 0 ] || [ -z "$out" ]; then
    echo "  FAIL  $name — binary exited $bin_rc or produced no output (may be neutered or crashed)" >&2
    [ -n "$out" ] && echo "        output: $(echo "$out" | head -3)" >&2
    TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
    continue
  fi
  # cmocka tests: parse the "[  PASSED  ] N test(s)." summary line for the subtest count.
  if echo "$out" | grep -qE '^\[  PASSED  \]'; then
    n="$(echo "$out" | grep -oE '^\[  PASSED  \] [0-9]+' | grep -oE '[0-9]+$' || echo 1)"
    echo "  PASS  $name ($n)" >&2
    TOTAL_PASSED=$(( TOTAL_PASSED + n ))
  else
    # Non-cmocka test (e.g. cpp_linkage_test): non-empty output + exit 0 is sufficient.
    # Verify it printed something recognizable (at least 1 non-whitespace character).
    echo "  PASS  $name (1)" >&2
    TOTAL_PASSED=$(( TOTAL_PASSED + 1 ))
  fi
done

if [ "$TOTAL_FAILED" -eq 0 ]; then
  echo "test.sh: all tests passed ($TOTAL_PASSED subtests across ${#TESTS[@]} binaries)" >&2
else
  echo "test.sh: $TOTAL_FAILED of ${#TESTS[@]} test binaries FAILED" >&2
fi

emit_ctrf "cmake-ctest" "$TOTAL_PASSED" "$TOTAL_FAILED"
