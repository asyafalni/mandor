# mandor ships as a single static binary; the image is just that binary.
# Consumers COPY it into their own images:
#   COPY --from=ghcr.io/asyafalni/mandor:latest /mandor /mandor
FROM scratch
ARG TARGETARCH
COPY dist/${TARGETARCH}/mandor /mandor
ENTRYPOINT ["/mandor"]
