#!/bin/sh
# Is mandor genuinely PID 1, and does it reap what gets reparented to it?
echo "worker-pid=$$"
echo "ppid=$(awk '{print $4}' /proc/$$/stat)"

# NOTE: this case covers PID-1 *identity* only. Orphan adoption and reaping
# live in t/orphan.sh, because getting that scenario right is fiddly: an
# earlier version here let the parent outlive the child, so this shell reaped
# its own child and mandor was never involved -- it reported zombies=0 while
# testing nothing at all.
exit 0
