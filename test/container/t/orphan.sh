#!/bin/sh
# Does mandor adopt AND reap orphans, leaving no zombie behind?
#
# Split across files on purpose: an earlier single-file version had the parent
# outlive the child, so the parent shell reaped its own child and mandor was
# never involved -- the test passed while proving nothing.
#
# Spawn several so a one-off reap cannot be mistaken for a working loop.
i=0
while [ $i -lt 5 ]; do
  sh /t/mid.sh
  i=$((i + 1))
done
echo "intermediate-parents-exited, 5 grandchildren orphaned"

# Outlive them, then inspect. `ps` counts zombies anywhere in the container;
# /proc/1/task/1/children lists what PID 1 still owns.
sleep 5
echo "zombies=$(ps -eo stat 2>/dev/null | grep -c '^Z')"
echo "pid1-children=[$(cat /proc/1/task/1/children 2>/dev/null)]"
exit 0
