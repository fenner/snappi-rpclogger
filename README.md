# snappi-rpclogger

This repository generates the Python and Go SDKs from an
[`open-traffic-generator/models`](https://github.com/open-traffic-generator/models)
release using Bill Fenner's RPC-logger-enabled OpenAPIArt builder.

Release tags deliberately match upstream models tags.  Thus a release for
`v1.61.0` can be used as a direct replacement for upstream `v1.61.0`:

```go
replace github.com/open-traffic-generator/snappi/gosnappi v1.61.0 => \
  github.com/fenner/snappi-rpclogger/gosnappi v1.61.0
```

The generated `go.mod` deliberately retains the upstream module path. That is
what makes the replacement transparent, including for generated internal
imports. Consumers should use the `replace` directive above rather than import
the Fenner repository path directly.

Run **Generate SDK release** with a tag such as `v1.61.0`.  It downloads that
release's `openapi.yaml`, resolves `fenner/openapiart`'s `rpclogger-builder`
branch to a commit, and generates and tests both SDKs. A real release creates
an orphan branch named `rpclogger-v1.61.0`, containing one root commit with
only generated output and provenance; it tags that commit as `v1.61.0` and
creates a GitHub release. The `main` branch remains builder-only.

The workflow defaults to `dry_run: true`: it performs generation and both
tests, then uploads the resulting `snappi`, `gosnappi`, requirements, and
provenance as a workflow artifact. It does not commit, tag, or create a
release. Set `dry_run` to `false` only after reviewing that run.

`Poll Models releases` runs daily at 09:17 UTC (and can also be run manually).
It queries the latest non-prerelease Models release and, when its exact tag is
not already present in this repository, performs the real release generation.
It uses the `rpclogger-builder` branch head and enables the documented narrow
OpenAPI-validation bypass. Scheduled workflows must remain on `main` and need
the repository's Actions workflow permission set to **Read and write**.

Set `skip_openapi_validation` only when a Models release fails OpenAPIArt's
final `openapi_spec_validator` check and you intentionally want to generate it
anyway. This bypasses that one check only; OpenAPIArt's other bundling checks
and the generated SDK tests still run. The exception is recorded in
`build-info.json`.

Every generated release contains `build-info.json`, including the model asset
digest and the exact resolved OpenAPIArt commit. The branch head is intentionally
used for new builds; its recorded SHA makes each completed release reproducible.
Completed builds also record the Go toolchain used inside the generated module.
CI and the local-test image start with Go 1.26 and set `GOTOOLCHAIN=auto` so
upstream dependencies can select a newer toolchain. Failed CI runs upload
generated files, available provenance, the model specification, and the
generation log as diagnostic artifacts. Dependency resolution failures are
fatal even when OpenAPIArt ignores its own `go mod tidy` exit status.

`Publish tagged release` publishes matching tags created outside the generator.
The generator itself creates the release because a tag pushed with the default
Actions `GITHUB_TOKEN` does not trigger another workflow.

For a local dry run (Python, Go, `protoc`, and `git` required):

```bash
export GOTOOLCHAIN=auto
python3 -u scripts/generate.py --models-tag v1.61.0
python -m pip install -r requirements.txt
python -c 'import snappi'
go -C gosnappi test ./...
```

Run this in a disposable clone or Git worktree: generation replaces the local
`snappi/` and `gosnappi/` directories. A container is also suitable; it needs
Python 3.11+, Go 1.26+, `protoc`, and `git`, with network access to GitHub and
the Go module proxy. The builder deliberately skips OpenAPIArt's `proto_doc/`
side effect because upstream does not publish that documentation either.

## Docker local test

Build the local-test image from the repository root:

```bash
docker build --tag snappi-rpclogger-test --file test/Dockerfile .
```

Use the wrapper to build the image, run generation/tests in a temporary
Docker-managed volume, and copy the output back with `docker cp`:

```bash
test/run-docker-test.sh --models-tag v1.61.0
```

To exercise an invalid OpenAPI specification, add `--skip-openapi-validation`.

To test an unpushed OpenAPIArt change, embed the local checkout in the test
image instead of cloning GitHub:

```bash
test/run-docker-test.sh --models-tag v1.61.0 \
  --openapiart-dir /home/fenner/src/openapiart
```

The local checkout's current Git SHA is recorded in `build-info.json`. This
option rebuilds the image and cannot be combined with `--skip-build`.

It prints a new `/tmp/snappi-rpclogger-output.*` directory containing
`snappi/`, `gosnappi/`, `requirements.txt`, and `build-info.json`. Supply
`--output DIR` to choose a destination. No host directory is bind-mounted.

The wrapper defaults `DOCKER_CONFIG` and `BUILDX_CONFIG` to a per-user
directory in `/tmp`, which avoids Buildx state writes below `$HOME/.docker`.
To set this manually for other Docker commands:

```bash
export DOCKER_CONFIG="/tmp/snappi-rpclogger-docker-$UID"
export BUILDX_CONFIG="$DOCKER_CONFIG/buildx"
mkdir -p "$BUILDX_CONFIG"
```
