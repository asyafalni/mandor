#!/bin/sh
# The grandchild. Outlives its parent, so the kernel reparents it to PID 1.
sleep 2
# NOTE: must be /proc/$$/stat, not /proc/self/stat. Inside $( ) the reader
# (awk) is its own process, so /proc/self would report awk's parent -- the
# grandchild shell -- and the reparenting would look like it never happened.
# $$ is expanded by this shell first, so it names the right process.
echo "grandchild-pid=$$ ppid=$(awk '{print $4}' /proc/$$/stat)"
exit 0
