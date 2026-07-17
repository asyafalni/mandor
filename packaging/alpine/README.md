# Alpine aports submission

1. Fork https://gitlab.alpinelinux.org/alpine/aports; copy this APKBUILD to
   `testing/mandor/APKBUILD`.
2. `abuild checksum && abuild -r` inside an Alpine container with
   `alpine-sdk` + `zig` installed (zig is in the community repo).
3. Caveat: aports' zig version may differ from `.zigversion`; if the build
   breaks, pin via a zig tarball in `makedepends`-less fetch or wait for
   aports zig to catch up — upstream tracks exactly one Zig release.
4. Open an MR titled `testing/mandor: new aport`; you are the maintainer of
   record. Promotion to `community/` needs a few release cycles of upkeep.
