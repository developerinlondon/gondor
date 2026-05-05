#!/usr/bin/env bash
# Boot gondor against a local assay + sysops checkout for development.
# Run from the repo root:
#
#   ./tests-lua/dev-run.sh             # binds 18787, talks to no engine
#   ./tests-lua/dev-run.sh --smoke     # runs the smoke test instead
#
# Override paths via ASSAY_ROOT (default ../assay) and PORT.

set -euo pipefail

ASSAY_ROOT="${ASSAY_ROOT:-$(realpath ../assay)}"
GONDOR_ROOT="${GONDOR_ROOT:-$(pwd)}"
PORT="${PORT:-18787}"

ASSAY_BIN="${ASSAY_ROOT}/target/release/assay"
SYSOPS_LIB_ROOT="${ASSAY_ROOT}/libs/sysops"

if [[ ! -x "$ASSAY_BIN" ]]; then
  echo "assay release binary missing — build with: (cd $ASSAY_ROOT && cargo build --release --bin assay)" >&2
  exit 1
fi

LUA_PATH="${ASSAY_ROOT}/libs/?.lua;${ASSAY_ROOT}/libs/?/init.lua;${ASSAY_ROOT}/libs/sysops/?.lua;${GONDOR_ROOT}/?.lua;${GONDOR_ROOT}/?/init.lua;;"

export SYSOPS_LIB_ROOT GONDOR_ROOT PORT LUA_PATH
export BRAND_DIR="${BRAND_DIR:-$GONDOR_ROOT/brand}"
export AUDIT_PATH="${AUDIT_PATH:-/tmp/gondor-dev-audit.log}"

if [[ "${1:-}" == "--smoke" ]]; then
  exec "$ASSAY_BIN" "$GONDOR_ROOT/tests-lua/smoke.test.lua"
fi

exec "$ASSAY_BIN" run "$GONDOR_ROOT/scripts/main.lua"
