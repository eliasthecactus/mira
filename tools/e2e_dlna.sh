#!/bin/bash
# End-to-end test of the DLNA path on one Mac: mock DLNA TV on localhost <-> Mira with a
# test pattern. Validates discovery (SSDP), SOAP control, the live HTTP MPEG-TS stream
# (mock TV), and decodability (ffmpeg).
#
#   tools/e2e_dlna.sh                # default: 8 s, then the "TV" stops playback
set -u
cd "$(dirname "$0")/.."

OUT="${E2E_OUT:-$(mktemp -d -t mira-e2e-dlna)}"
mkdir -p "$OUT"
DURATION="${E2E_DURATION:-8}"
MIRA=.build/debug/Mira
MIRA_ARGS="${MIRA_ARGS---test-pattern}"
# E2E_STOP_AFTER=N: stop Mira after N s (tests the Stop action)
# E2E_DLNA_DIRECT=1: give Mira the description URL instead of discovering the TV via SSDP

swift build >/dev/null || { echo "build failed"; exit 1; }

python3 tools/mock_dlna.py --duration "$DURATION" --timeout "${E2E_TIMEOUT:-$((DURATION + 40))}" \
    --out "$OUT/received.ts" "$@" > "$OUT/tv.log" 2>&1 &
TV=$!
sleep 1

DIRECT=""; [ -n "${E2E_DLNA_DIRECT:-}" ] && DIRECT="--dlna-url http://127.0.0.1:49152/description.xml"
"$MIRA" connect 127.0.0.1 --dlna $DIRECT $MIRA_ARGS --no-reconnect > "$OUT/mira.log" 2>&1 &
MIRA_PID=$!
if [ -n "${E2E_STOP_AFTER:-}" ]; then (sleep "$E2E_STOP_AFTER"; kill -INT $MIRA_PID) & fi

wait $TV; TV_STATUS=$?
sleep 1
kill -INT $MIRA_PID 2>/dev/null; sleep 1; kill -9 $MIRA_PID 2>/dev/null
wait $MIRA_PID 2>/dev/null

echo "-- mock DLNA TV --------------------------"; cat "$OUT/tv.log"
echo "-- Mira ----------------------------------"; cat "$OUT/mira.log"

STATUS=$TV_STATUS
if [ -n "${E2E_EXPECT_LOG:-}" ]; then
    if grep -qE "$E2E_EXPECT_LOG" "$OUT/mira.log"; then echo "found expected log line: $E2E_EXPECT_LOG"
    else echo "FAIL: Mira's log has no line matching: $E2E_EXPECT_LOG"; STATUS=1; fi
fi
if [ -s "$OUT/received.ts" ] && command -v ffprobe >/dev/null; then
    echo "-- ffprobe -------------------------------"
    ffprobe -v error -show_entries stream=codec_name,profile,width,height,sample_rate,channels -of compact "$OUT/received.ts"
    echo "-- ffmpeg decode check -------------------"
    ERRORS=$(ffmpeg -v error -i "$OUT/received.ts" -f null - 2>&1 | grep -v "^$" | head -20)
    if [ -n "$ERRORS" ]; then echo "$ERRORS"; echo "FAIL: decoder reported errors"; STATUS=1
    else echo "decoded cleanly"; fi
fi

echo "------------------------------------------"
echo "artifacts: $OUT"
[ $STATUS -eq 0 ] && echo "E2E PASS" || echo "E2E FAIL"
exit $STATUS
