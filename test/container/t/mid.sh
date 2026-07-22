#!/bin/sh
# The intermediate parent: spawn the grandchild and die immediately, which is
# what orphans it. Without this the parent would reap its own child and mandor
# would never be involved.
sh /t/gchild.sh &
exit 0
