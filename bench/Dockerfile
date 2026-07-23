# One image with mandor and the supervisors it is compared against, so the
# numbers come from the same kernel, same libc, same container — the only fair
# way to measure PID-1 behaviour. mandor is copied in (built libc-free);
# the rest come from Alpine's repos.
FROM alpine:3.20
RUN apk add --no-cache tini dumb-init s6 supervisor coreutils procps
COPY mandor /usr/bin/mandor
COPY workload.sh /workload.sh
RUN chmod +x /usr/bin/mandor /workload.sh
ENTRYPOINT ["/bin/sh"]
