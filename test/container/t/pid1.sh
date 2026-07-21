#!/bin/sh
# Is mandor genuinely PID 1, and does it reap what gets reparented to it?
echo "worker-pid=$$"
echo "ppid=$(awk '{print $4}' /proc/$$/stat)"

# Orphan a grandchild: it exits after its parent, so the kernel reparents it
# to PID 1. If mandor does not reap it, it stays a zombie forever -- the
# classic failure this whole class of tool exists to prevent.
( sleep 1; echo "orphan-done" ) &
sleep 0.2
echo "spawned-orphan"
sleep 3

# Count zombies visible in the container. A correct PID 1 leaves none.
z=$(ps -eo stat 2>/dev/null | grep -c '^Z' || echo 0)
echo "zombies=$z"
exit 0
