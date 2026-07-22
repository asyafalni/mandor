# The app side of the end-to-end: mandor as PID 1 with a worker that crashes,
# and the `photon` key set so the incident forwards by itself. Built at test
# time because the binary and the rendered config are staged in beside it.
FROM alpine:3.20
COPY mandor /mandor
COPY mandor.toml /mandor.toml
ENTRYPOINT ["/mandor", "--config=/mandor.toml"]
