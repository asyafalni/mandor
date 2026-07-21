#!/bin/sh
# Grandchild TERM handling under real PID 1 -- the v1.5.1 scenario. The leader
# handles TERM and exits promptly; the grandchild needs its own handler to run
# to completion inside stop_grace rather than being cut short by the reaper's
# post-death process-group sweep.
(
  trap 'echo "grandchild-drained"; exit 0' TERM
  echo "grandchild-ready"
  while :; do sleep 0.2; done
) &
trap 'echo "leader-term"; exit 0' TERM
echo "leader-ready"
while :; do sleep 0.2; done
