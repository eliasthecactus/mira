#!/bin/bash
# End-to-end test of pairing with a hotel/venue casting gateway: the mock gateway
# refuses the Cast port until Mira pairs (link, form or consent page), then a mock
# Cast receiver checks the stream.
#
#   tools/e2e_pairing.sh link      # pair with the QR-code link
#   tools/e2e_pairing.sh form      # pair with the code; Mira finds and submits the form
#   tools/e2e_pairing.sh consent   # needs a person: Mira must hand over to the browser and give up
#   tools/e2e_pairing.sh consent-user  # ...and a (simulated) person finishes it: Mira connects
set -u
cd "$(dirname "$0")/.."
MODE="${1:-link}"
OPEN=/usr/bin/true
if [ "$MODE" = consent-user ]; then MODE=consent; OPEN="$PWD/tools/fake_browser_consent.sh"; USER_FINISHES=1; fi
OUT="${E2E_OUT:-$(mktemp -d -t mira-e2e-pair)}"
mkdir -p "$OUT"
PY=python3; [ -x .venv/bin/python ] && PY=.venv/bin/python
cleanup() { pkill -f "mock_cast.py --port 18009" 2>/dev/null; pkill -f mock_gateway.py 2>/dev/null; }
trap cleanup EXIT
cleanup
swift build >/dev/null || { echo "build failed"; exit 1; }

$PY tools/mock_gateway.py --mode "$MODE" --code 7F6GY --timeout 40 -- --duration 5 --timeout 30 > "$OUT/gateway.log" 2>&1 &
GW=$!
for _ in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8088/ && break; sleep 0.5; done

if [ "$MODE" = link ]; then PAIR="http://127.0.0.1:8088/pair?pairCode=7F6GY"; else PAIR="7F6GY"; fi
MIRA_GATEWAY_WEB_PORT=8088 MIRA_OPEN_COMMAND="$OPEN" MIRA_PAIR_WAIT=6 \
    .build/debug/Mira connect 127.0.0.1 --cast --port 18009 --pair "$PAIR" --test-pattern --no-reconnect > "$OUT/mira.log" 2>&1 &
MIRA_PID=$!

if [ "$MODE" = consent ] && [ -z "${USER_FINISHES:-}" ]; then
    # Nobody ticks the box: Mira must open the page for the user and then give up.
    wait $MIRA_PID; MIRA_STATUS=$?
    kill $GW 2>/dev/null
    cat "$OUT/gateway.log" "$OUT/mira.log"
    if [ $MIRA_STATUS -ne 0 ] && grep -q "Finish the pairing in the browser" "$OUT/mira.log" && grep -q "still doesn't let this Mac connect" "$OUT/mira.log"; then
        echo "E2E PASS"; exit 0
    fi
    echo "E2E FAIL"; exit 1
fi

wait $GW; STATUS=$?
sleep 1
kill -INT $MIRA_PID 2>/dev/null; sleep 1; kill -9 $MIRA_PID 2>/dev/null
cat "$OUT/gateway.log"; echo "-- Mira --"; cat "$OUT/mira.log"
if grep -q "7F6GY" "$OUT/mira.log"; then echo "FAIL: the pairing code leaked into the log"; STATUS=1; fi
[ $STATUS -eq 0 ] && echo "E2E PASS" || echo "E2E FAIL"
exit $STATUS
