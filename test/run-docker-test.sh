#!/usr/bin/env bash
# Generate and test one models release in the local Docker test image.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test/run-docker-test.sh --models-tag v1.61.0 [options]

Options:
  --openapiart-ref REF  OpenAPIArt branch or tag (default: rpclogger-builder)
  --openapiart-dir DIR  Embed and use a local OpenAPIArt checkout
  --image NAME          Docker image name (default: snappi-rpclogger-test)
  --skip-build          Reuse an existing image instead of building it
  --skip-openapi-validation
                        Skip only the final OpenAPI specification validation
  --output DIR          Copy generated SDKs here (default: a new /tmp directory)
  -h, --help            Show this help

Docker never bind-mounts the source checkout or /tmp. It seeds a temporary
Docker-managed volume from the image, runs generation and tests there, then
uses docker cp to copy the generated SDKs to the output directory.
EOF
}

models_tag=
openapiart_ref=rpclogger-builder
openapiart_dir=
image=snappi-rpclogger-test
build_image=true
output=
skip_openapi_validation=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models-tag)
      models_tag=${2:?--models-tag requires a value}
      shift 2
      ;;
    --openapiart-ref)
      openapiart_ref=${2:?--openapiart-ref requires a value}
      shift 2
      ;;
    --openapiart-dir)
      openapiart_dir=${2:?--openapiart-dir requires a value}
      shift 2
      ;;
    --image)
      image=${2:?--image requires a value}
      shift 2
      ;;
    --skip-build)
      build_image=false
      shift
      ;;
    --skip-openapi-validation)
      skip_openapi_validation=true
      shift
      ;;
    --output)
      output=${2:?--output requires a value}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ $models_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
  echo "--models-tag must look like v1.61.0" >&2
  exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

if [[ -n $openapiart_dir && ! -d $openapiart_dir/openapiart ]]; then
  echo "--openapiart-dir is not an OpenApiArt checkout: $openapiart_dir" >&2
  exit 2
fi

temp_root=${SNAPPI_RPCLOGGER_TMPDIR:-/tmp}

if [[ -z $output ]]; then
  output=$(mktemp -d "$temp_root/snappi-rpclogger-output.XXXXXX")
else
  mkdir -p "$output"
fi

# Some environments cannot use Buildx's default $HOME/.docker state directory.
# Let callers override either location, but use an isolated writable /tmp state
# directory by default.
docker_config=${DOCKER_CONFIG:-"$temp_root/snappi-rpclogger-docker-${UID}"}
buildx_config=${BUILDX_CONFIG:-"$docker_config/buildx"}
mkdir -p "$docker_config" "$buildx_config"
export DOCKER_CONFIG="$docker_config"
export BUILDX_CONFIG="$buildx_config"

build_context=$repo_root
openapiart_container_dir=
openapiart_commit=
if [[ -n $openapiart_dir ]]; then
  if ! $build_image; then
    echo "--openapiart-dir requires rebuilding the image; omit --skip-build" >&2
    exit 2
  fi
  build_context=$(mktemp -d "$temp_root/snappi-rpclogger-context.XXXXXX")
  cp -a "$repo_root/." "$build_context/"
  cp -a "$openapiart_dir" "$build_context/local-openapiart"
  openapiart_container_dir=/workspace/local-openapiart
  openapiart_commit=$(git -C "$openapiart_dir" rev-parse HEAD)
fi

if $build_image; then
  docker build --tag "$image" --file "$build_context/test/Dockerfile" "$build_context"
fi

suffix="${UID}-${RANDOM}-${RANDOM}"
volume="snappi-rpclogger-test-$suffix"
container="snappi-rpclogger-test-$suffix"
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
  docker volume rm --force "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker volume create "$volume" >/dev/null
docker create --name "$container" \
  --volume "$volume:/workspace" \
  --env MODELS_TAG="$models_tag" \
  --env OPENAPIART_REF="$openapiart_ref" \
  --env OPENAPIART_DIR="$openapiart_container_dir" \
  --env OPENAPIART_COMMIT="$openapiart_commit" \
  --env SKIP_OPENAPI_VALIDATION="$skip_openapi_validation" \
  --entrypoint /bin/bash \
  "$image" \
  -c 'set -euo pipefail; cp -a /seed/. /workspace/; cd /workspace; arguments=(--models-tag "$MODELS_TAG"); if [[ -n "$OPENAPIART_DIR" ]]; then arguments+=(--openapiart-dir "$OPENAPIART_DIR" --openapiart-commit "$OPENAPIART_COMMIT"); else arguments+=(--openapiart-ref "$OPENAPIART_REF"); fi; if [[ "$SKIP_OPENAPI_VALIDATION" == true ]]; then arguments+=(--skip-openapi-validation); fi; /usr/local/bin/snappi-rpclogger-test generate "${arguments[@]}"; /usr/local/bin/snappi-rpclogger-test test' \
  >/dev/null
docker start --attach "$container"

docker cp "$container:/workspace/gosnappi" "$output/gosnappi"
docker cp "$container:/workspace/snappi" "$output/snappi"
docker cp "$container:/workspace/requirements.txt" "$output/requirements.txt"
docker cp "$container:/workspace/build-info.json" "$output/build-info.json"
echo "Generated SDKs copied to: $output"
