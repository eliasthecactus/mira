#!/bin/bash
# End-to-end test of the Google Cast path on one Mac: mock Cast receiver on localhost
# <-> Mira with a test pattern. Validates the control handshake, the encrypted Cast
# RTP stream with ACK/NACK feedback (mock receiver), and decodability (ffmpeg).
#
#   tools/e2e_cast.sh                       # default: 8 s, H.264 + Opus
#   tools/e2e_cast.sh --loss 5              # extra args go to the mock receiver
#   MIRA_ARGS="--test-pattern --codec hevc" tools/e2e_cast.sh --video-codecs hevc,h264
set -u
cd "$(dirname "$0")/.."

OUT="${E2E_OUT:-$(mktemp -d -t mira-e2e-cast)}"
mkdir -p "$OUT"
DURATION="${E2E_DURATION:-8}"
MIRA=.build/debug/Mira
MIRA_ARGS="${MIRA_ARGS---test-pattern}"
PY=python3; [ -x .venv/bin/python ] && PY=.venv/bin/python    # needs the cryptography package
# E2E_EXPECT_LOG="regex"   fail unless Mira's log matches
# E2E_SKIP_DECODE=1        skip the ffmpeg decode check
# E2E_STOP_AFTER=N         stop Mira after N s (tests STOP)

swift build >/dev/null || { echo "build failed"; exit 1; }

$PY tools/mock_cast.py --duration "$DURATION" --timeout "${E2E_TIMEOUT:-$((DURATION + 40))}" \
    --out "$OUT/received.video" "$@" > "$OUT/receiver.log" 2>&1 &
RECV=$!
# Wait until the mock receiver listens (Python can start slowly on a fresh CI machine).
for _ in $(seq 1 60); do nc -z 127.0.0.1 8009 2>/dev/null && break; sleep 0.5; done

"$MIRA" connect 127.0.0.1 --cast $MIRA_ARGS --no-reconnect > "$OUT/mira.log" 2>&1 &
MIRA_PID=$!

# E2E_STOP_AFTER=N: stop Mira (Ctrl-C) after N s; it must send STOP to the device.
if [ -n "${E2E_STOP_AFTER:-}" ]; then
    (sleep "$E2E_STOP_AFTER"; kill -INT $MIRA_PID) &
fi

wait $RECV; RECV_STATUS=$?
sleep 1
kill -INT $MIRA_PID 2>/dev/null; sleep 1; kill -9 $MIRA_PID 2>/dev/null
wait $MIRA_PID 2>/dev/null

echo "-- mock Cast receiver --------------------"; cat "$OUT/receiver.log"
echo "-- Mira ----------------------------------"; cat "$OUT/mira.log"

STATUS=$RECV_STATUS
if [ -n "${E2E_EXPECT_LOG:-}" ]; then
    if grep -qE "$E2E_EXPECT_LOG" "$OUT/mira.log"; then echo "found expected log line: $E2E_EXPECT_LOG"
    else echo "FAIL: Mira's log has no line matching: $E2E_EXPECT_LOG"; STATUS=1; fi
fi
if [ -z "${E2E_SKIP_DECODE:-}" ] && [ -s "$OUT/received.video" ] && command -v ffprobe >/dev/null; then
    FMT=h264; grep -qE "Picked.* hevc" "$OUT/receiver.log" && FMT=hevc
    echo "-- ffprobe -------------------------------"
    ffprobe -v error -f $FMT -show_entries stream=codec_name,profile,width,height -of compact "$OUT/received.video"
    echo "-- ffmpeg decode check -------------------"
    ERRORS=$(ffmpeg -v error -f $FMT -i "$OUT/received.video" -f null - 2>&1 | grep -v "^$" | head -20)
    if [ -n "$ERRORS" ]; then echo "$ERRORS"; echo "FAIL: decoder reported errors"; STATUS=1
    else echo "decoded cleanly"; fi
    ffmpeg -v error -y -f $FMT -i "$OUT/received.video" -frames:v 1 "$OUT/frame.png" && echo "frame: $OUT/frame.png"
fi

echo "------------------------------------------"
echo "artifacts: $OUT"
[ $STATUS -eq 0 ] && echo "E2E PASS" || echo "E2E FAIL"
exit $STATUS
