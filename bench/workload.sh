#!/bin/sh
# The worker every supervisor runs, so startup and signal latency are measured
# against identical work: install a TERM handler, announce readiness, idle.
trap 'echo "worker-term $(date +%s%N)"; exit 0' TERM
echo "worker-ready $(date +%s%N)"
while :; do sleep 0.1; done
