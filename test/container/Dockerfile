# Real PID-1 semantics only appear inside a container (CLAUDE.md). Everything
# this session was verified in WSL, where mandor is an ordinary process --
# notably the v1.5.1 process-group change, whose whole point is what happens
# to orphaned grandchildren when their leader is reaped by PID 1.
FROM alpine:3.20
RUN apk add --no-cache procps
COPY mandor /mandor
COPY t /t
ENTRYPOINT ["/mandor"]
