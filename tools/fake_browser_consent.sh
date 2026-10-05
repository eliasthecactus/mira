#!/bin/bash
# Stand-in for a person in the browser (tools/e2e_pairing.sh consent-user): after a
# moment, ticks the consent box on the mock gateway's pairing page.
( sleep 2; curl -s -o /dev/null -d "pairCode=7F6GY&terms=on" "http://127.0.0.1:8088/pair" ) &
