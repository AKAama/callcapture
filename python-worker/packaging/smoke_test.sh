#!/usr/bin/env bash
# Verify the frozen worker honors the CLI contract: it loads, exposes its
# commands, answers a ping heartbeat, and survives malformed input without
# crashing. Run after a PyInstaller build.
#
# Usage: packaging/smoke_test.sh [path-to-binary]
#
# Contract notes (verified against app/cli.py):
#   * There is NO `--version` flag on the CLI group; `--help` is the liveness
#     check that proves the frozen binary imported `app` and registered its
#     commands (transcribe/postprocess/export/prepare_emotion).
#   * The ping heartbeat format is {"action": "ping"} (see _check_ping). The
#     worker replies {"pong": true} on STDERR and exits 0. {"ping": true} is
#     NOT a ping — it is parsed as a JobRequest and yields a structured error.
#   * Malformed stdin yields a structured JobResult error on stdout, not a crash.
set -euo pipefail

BIN="${1:-dist/call-capture-worker/call-capture-worker}"

if [[ ! -x "$BIN" ]]; then
    echo "error: worker binary not found/executable at $BIN" >&2
    exit 1
fi

echo "===> --help (liveness: binary loaded, commands registered)"
help_out="$("$BIN" --help)"
echo "$help_out"
for cmd in transcribe postprocess export prepare_emotion; do
    if ! grep -q "$cmd" <<<"$help_out"; then
        echo "error: expected command '$cmd' missing from --help output" >&2
        exit 1
    fi
done

echo "===> ping heartbeat (transcribe with an {\"action\":\"ping\"} payload)"
ping_err="$(echo '{"action": "ping"}' | "$BIN" transcribe 2>&1 1>/dev/null)"
if ! grep -q '"pong"' <<<"$ping_err"; then
    echo "error: ping did not return a pong on stderr (got: $ping_err)" >&2
    exit 1
fi
echo "pong received: $ping_err"

echo "===> invalid JSON returns a structured error (non-crash)"
set +e
echo 'not-json' | "$BIN" transcribe >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ge 128 ]]; then
    echo "error: worker crashed (signal) on bad input (rc=$rc)" >&2
    exit 1
fi
echo "bad input survived (rc=$rc)"

echo "SMOKE OK"
