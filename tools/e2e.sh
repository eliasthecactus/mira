#!/bin/bash
# End-to-end test on one Mac: mock MICE sink on localhost ↔ Mira with a test pattern.
# Validates the handshake, the RTP/TS stream (mock sink), and decodability (ffmpeg).
#
#   tools/e2e.sh                  # default: 8 s, audio on
#   tools/e2e.sh --no-audio       # extra args go to the mock sink
#   MIRA_ARGS="" tools/e2e.sh     # real screen capture instead of the test pattern
set -u
cd "$(dirname "$0")/.."

OUT="${E2E_OUT:-$(mktemp -d -t mira-e2e)}"
mkdir -p "$OUT"
DURATION="${E2E_DURATION:-8}"
MIRA=.build/debug/Mira
MIRA_ARGS="${MIRA_ARGS---test-pattern}"   # e.g. MIRA_ARGS="" to capture the real screen
PY=python3; [ -x .venv/bin/python ] && PY=.venv/bin/python    # security tests need pyOpenSSL
# E2E_EXPECT_LOG="regex"   fail unless Mira's log matches (e.g. a bitrate change)
# E2E_SKIP_DECODE=1        skip the ffmpeg decode check (lossy runs)

swift build >/dev/null || { echo "build failed"; exit 1; }

$PY tools/mock_sink.py --bind 127.0.0.1 --duration "$DURATION" --idr-at 3 --timeout $((DURATION + 25)) \
    --out "$OUT/received.ts" "$@" > "$OUT/sink.log" 2>&1 &
SINK=$!
sleep 1

"$MIRA" connect 127.0.0.1 $MIRA_ARGS --no-reconnect --dump-ts "$OUT/sent.ts" > "$OUT/mira.log" 2>&1 &
MIRA_PID=$!

# Wait for the sink to finish (it tears down after $DURATION s of streaming).
wait $SINK; SINK_STATUS=$?
sleep 1
kill -INT $MIRA_PID 2>/dev/null; sleep 1; kill -9 $MIRA_PID 2>/dev/null
wait $MIRA_PID 2>/dev/null

echo "── mock sink ─────────────────────────────"; cat "$OUT/sink.log"
echo "── Mira ──────────────────────────────────"; cat "$OUT/mira.log"

STATUS=$SINK_STATUS
if [ -n "${E2E_EXPECT_LOG:-}" ]; then
    if grep -qE "$E2E_EXPECT_LOG" "$OUT/mira.log"; then echo "found expected log line: $E2E_EXPECT_LOG"
    else echo "FAIL: Mira's log has no line matching: $E2E_EXPECT_LOG"; STATUS=1; fi
fi
if [ -z "${E2E_SKIP_DECODE:-}" ] && [ -s "$OUT/received.ts" ] && command -v ffprobe >/dev/null; then
    echo "── ffprobe ───────────────────────────────"
    ffprobe -v error -show_entries stream=codec_name,profile,level,width,height,r_frame_rate,sample_rate,channels \
        -of compact "$OUT/received.ts"
    echo "── ffmpeg decode check ───────────────────"
    ERRORS=$(ffmpeg -v error -i "$OUT/received.ts" -f null - 2>&1 | grep -v "^$" | head -20)
    if [ -n "$ERRORS" ]; then echo "$ERRORS"; echo "FAIL: decoder reported errors"; STATUS=1
    else echo "decoded cleanly"; fi
    ffmpeg -v error -y -ss 2 -i "$OUT/received.ts" -frames:v 1 "$OUT/frame.png" && echo "frame: $OUT/frame.png"
fi

echo "──────────────────────────────────────────"
echo "artifacts: $OUT"
[ $STATUS -eq 0 ] && echo "E2E PASS" || echo "E2E FAIL"
exit $STATUS
