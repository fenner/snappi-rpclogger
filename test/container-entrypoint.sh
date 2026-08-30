#!/usr/bin/env bash
set -euo pipefail

venv=.build/venv

setup_venv() {
  if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv"
  fi
  "$venv/bin/python" -m pip install --upgrade pip
}

case "${1:-help}" in
  generate)
    shift
    setup_venv
    exec "$venv/bin/python" scripts/generate.py "$@"
    ;;
  test)
    setup_venv
    "$venv/bin/python" -m pip install -r requirements.txt
    "$venv/bin/python" -c 'import snappi'
    exec go -C gosnappi test ./...
    ;;
  shell)
    exec bash
    ;;
  help|--help|-h)
    cat <<'EOF'
Usage:
  generate --models-tag v1.61.0 [--openapiart-ref rpclogger-builder]
  test
  shell

Run the container with the repository bind-mounted at /workspace and your
host UID/GID. See README.md for examples.
EOF
    ;;
  *)
    exec "$@"
    ;;
esac
