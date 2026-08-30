# syntax=docker/dockerfile:1
FROM golang:1.25-bookworm

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        git \
        libprotobuf-dev \
        python3 \
        python3-venv \
        protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

RUN go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.2.0 \
    && go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.28.1 \
    && go install golang.org/x/tools/cmd/goimports@v0.36.0

ENV PATH="/go/bin:${PATH}"
WORKDIR /workspace

COPY test/container-entrypoint.sh /usr/local/bin/snappi-rpclogger-test
RUN chmod 0755 /usr/local/bin/snappi-rpclogger-test
# Docker receives this build context from the client; it never needs to
# bind-mount the source checkout. The wrapper copies it into a named volume.
COPY . /seed
ENTRYPOINT ["/usr/local/bin/snappi-rpclogger-test"]
CMD ["help"]
