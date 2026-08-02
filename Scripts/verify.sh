#!/usr/bin/env bash
#
# FalaDan canonical verification gate.
#
# This is THE command that decides whether work is done. Run it whole; never
# hand-compose the steps, and never report success from a partial run.
#
#   ./Scripts/verify.sh          # build + test + working-tree check
#   ./Scripts/verify.sh --dirty  # skip the clean-working-tree check (mid-task)
#
# Why the -Xswiftc/-Xlinker flags below: on a Command Line Tools install with no
# full Xcode, Swift Testing is present but unusable out of the box. `Testing.framework`
# lives in .../Library/Developer/Frameworks, while the `lib_TestingInterop.dylib` it
# links against lives in .../Library/Developer/usr/lib — a different directory, and
# neither is on the default search path. Bare `swift test` fails twice over: first
# "no such module 'Testing'" at compile time, then a dlopen failure at run time.
# Both paths must be supplied. Remove these only if a full Xcode is installed and
# selected via xcode-select.

set -euo pipefail

cd "$(dirname "$0")/.."

CHECK_CLEAN=1
[[ "${1:-}" == "--dirty" ]] && CHECK_CLEAN=0

DEVDIR="$(xcode-select -p)"
FRAMEWORKS="$DEVDIR/Library/Developer/Frameworks"
INTEROP_LIB="$DEVDIR/Library/Developer/usr/lib"

TEST_FLAGS=()
if [[ -d "$FRAMEWORKS" && -f "$INTEROP_LIB/lib_TestingInterop.dylib" ]]; then
  TEST_FLAGS=(
    -Xswiftc -F -Xswiftc "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$INTEROP_LIB"
  )
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

step "Build"
swift build || fail "swift build"

step "Test"
swift test "${TEST_FLAGS[@]}" || fail "swift test"

if [[ $CHECK_CLEAN -eq 1 ]]; then
  step "Working tree"
  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
    fail "working tree is dirty — commit or stash before claiming done"
  fi
  echo "clean"
fi

printf '\n\033[32mVERIFY PASSED\033[0m\n'
