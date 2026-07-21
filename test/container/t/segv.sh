#!/bin/sh
# Die by signal so mandor must map it to 128+N as PID 1.
echo "about to segv"
kill -SEGV $$
