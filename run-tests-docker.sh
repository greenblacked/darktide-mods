#!/usr/bin/env bash
# Run this repo's runnable checks inside a Linux PowerShell container.
#
# Usage:
#   ./run-tests-docker.sh              # validator + exit-3 guards + Lock slice
#   ./run-tests-docker.sh validate     # validator only
#   ./run-tests-docker.sh lock         # the platform-independent Pester slice only
#   ./run-tests-docker.sh shell        # interactive pwsh in the container
#   ./run-tests-docker.sh full         # the whole suite, expect ~70 environmental failures
#
# Exit codes: 0 everything asked for passed, 1 something failed, 2 docker unusable
# (not installed, or installed but the daemon is not running).
#
# This is NOT the full gate. The Pester suite is Windows-only by construction and a
# Linux container does not change that. See .claude/skills/validate-change/SKILL.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-darktide-mods-test}"
MODE="${1:-all}"

# 'command -v docker' only proves the CLI exists. Docker Desktop installed but not
# running - the normal state on a Mac until you start it - sails past that check and
# fails several lines later inside 'docker build', with a raw
# /var/run/docker.sock connect error and exit 1 rather than the 2 promised above.
# 'docker info' is the cheapest call that needs the daemon to answer.
if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found on PATH" >&2
    exit 2
fi
if ! docker info >/dev/null 2>&1; then
    echo "docker is installed but the daemon is not responding - start Docker and try again." >&2
    exit 2
fi

# Mount read-only. These scripts delete and overwrite files for a living; a check run
# has no business writing into the checkout, and :ro makes that structural rather than
# a matter of trust. Pester's own fixtures go to $TMPDIR inside the container.
run() { docker run --rm --platform linux/amd64 -v "$REPO_DIR:/repo:ro" "$IMAGE" "$@"; }

# Same shape as the CI ubuntu job: assert the exit code, not just the text.
check() {
  local want=$1 label=$2; shift 2
  local got=0
  set +e
  run "$@"
  got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    echo "FAILED: $label - expected exit $want, got $got" >&2
    return 1
  fi
  echo "ok: $label -> $got"
}

echo "==> building $IMAGE"
docker build --platform linux/amd64 -f "$REPO_DIR/Dockerfile.test" -t "$IMAGE" "$REPO_DIR"

rc=0

case "$MODE" in
  shell)
    exec docker run --rm -it --platform linux/amd64 -v "$REPO_DIR:/repo:ro" "$IMAGE" pwsh -NoProfile
    ;;
  full)
    echo "==> full Pester suite (expect ~70 environmental failures off Windows)"
    run pwsh -NoProfile -File ./Invoke-Tests.ps1 -AllowNonWindows -SkipValidator || rc=$?
    ;;
  validate)
    echo
    echo "==> Test-Modpack.ps1 (validator, with PSScriptAnalyzer)"
    run pwsh -NoProfile -File ./Test-Modpack.ps1 || rc=$?
    ;;
  lock)
    echo
    echo "==> Pester: Lock.Tests.ps1 (platform-independent)"
    run pwsh -NoProfile -File ./Invoke-Tests.ps1 -AllowNonWindows -Path Lock -SkipValidator || rc=$?
    ;;
  all)
    echo
    echo "==> Test-Modpack.ps1 (validator, with PSScriptAnalyzer)"
    run pwsh -NoProfile -File ./Test-Modpack.ps1 || rc=$?

    if [ "$rc" -eq 0 ]; then
      echo
      echo "==> Invoke-Tests.ps1 (expect exit 3: validator passed, suite skipped)"
      check 3 "validator passed, suite skipped" \
            pwsh -NoProfile -File ./Invoke-Tests.ps1 || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      echo
      echo "==> Invoke-Tests.ps1 -SkipValidator (expect exit 3)"
      check 3 "nothing can run (-SkipValidator off Windows)" \
            pwsh -NoProfile -File ./Invoke-Tests.ps1 -SkipValidator || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      echo
      echo "==> Pester: Lock.Tests.ps1 (platform-independent)"
      check 0 "-AllowNonWindows genuinely runs Pester" \
            pwsh -NoProfile -File ./Invoke-Tests.ps1 -AllowNonWindows -Path Lock -Output None -SkipValidator || rc=$?
    fi
    ;;
  *)
    echo "usage: $0 [all|validate|lock|full|shell]" >&2
    exit 2
    ;;
esac

echo
echo "------------------------------------------------------------"
if [ "$rc" -eq 0 ]; then
  echo "PASS - but only the checks a Linux container can run."
  echo "The Windows-only Pester tests did not execute. Push the branch and read"
  echo "the 'validate' job on windows-latest for the real verdict."
else
  echo "FAILED (exit $rc)"
fi
exit "$rc"
