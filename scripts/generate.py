#!/usr/bin/env python3
"""Generate gosnappi from one immutable models-release asset."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import urlopen

MODELS_REPOSITORY = "open-traffic-generator/models"
OPENAPIART_REPOSITORY = "https://github.com/fenner/openapiart.git"
OPENAPIART_DEFAULT_REF = "rpclogger-builder"
# Keep this upstream identity: consumers replace this module with this repo.
GO_MODULE = "github.com/open-traffic-generator/snappi/gosnappi"


def run(*command: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def checked_tag(value: str) -> str:
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", value):
        raise ValueError("models tag must look like v1.61.0")
    return value


def download_models_asset(tag: str, destination: Path) -> str:
    url = f"https://github.com/{MODELS_REPOSITORY}/releases/download/{tag}/openapi.yaml"
    try:
        with urlopen(url) as response, destination.open("wb") as output:
            shutil.copyfileobj(response, output)
    except Exception as error:
        raise RuntimeError(f"could not download {url}: {error}") from error
    return url


def checkout_openapiart(build_dir: Path, ref: str) -> tuple[Path, str]:
    checkout = build_dir / "openapiart"
    if checkout.exists():
        shutil.rmtree(checkout)
    run("git", "clone", "--no-checkout", OPENAPIART_REPOSITORY, str(checkout))
    run("git", "fetch", "--depth=1", "origin", ref, cwd=checkout)
    commit = run("git", "rev-parse", "FETCH_HEAD", cwd=checkout)
    run("git", "checkout", "--detach", commit, cwd=checkout)
    return checkout, commit


def use_local_openapiart(path: Path, commit: str | None) -> tuple[Path, str]:
    checkout = path.resolve()
    if not (checkout / "openapiart").is_dir():
        raise RuntimeError(f"{checkout} is not an OpenApiArt checkout")
    if commit is None:
        commit = run("git", "rev-parse", "HEAD", cwd=checkout)
    return checkout, commit


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_commit_or_none(root: Path) -> str | None:
    try:
        return run("git", "rev-parse", "--verify", "HEAD", cwd=root)
    except subprocess.CalledProcessError:
        return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-tag", required=True, type=checked_tag)
    parser.add_argument("--openapiart-ref", default=OPENAPIART_DEFAULT_REF)
    parser.add_argument(
        "--openapiart-dir",
        type=Path,
        help="use a local OpenApiArt checkout instead of cloning --openapiart-ref",
    )
    parser.add_argument(
        "--openapiart-commit",
        help="commit recorded for --openapiart-dir when its .git directory is unavailable",
    )
    parser.add_argument(
        "--skip-openapi-validation",
        action="store_true",
        help="skip only OpenAPIArt's final openapi_spec_validator check",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    build_dir = root / ".build"
    build_dir.mkdir(exist_ok=True)
    openapi = build_dir / "openapi.yaml"
    asset_url = download_models_asset(args.models_tag, openapi)
    if args.openapiart_dir is None:
        openapiart_dir, openapiart_commit = checkout_openapiart(
            build_dir, args.openapiart_ref
        )
        openapiart_ref = args.openapiart_ref
        openapiart_source = "github"
    else:
        openapiart_dir, openapiart_commit = use_local_openapiart(
            args.openapiart_dir, args.openapiart_commit
        )
        openapiart_ref = str(openapiart_dir)
        openapiart_source = "local"
    subprocess.check_call([sys.executable, "-m", "pip", "install", str(openapiart_dir)])
    sys.path.insert(0, str(openapiart_dir))
    import openapiart  # pylint: disable=import-outside-toplevel

    if args.skip_openapi_validation:
        # OpenApiArt currently has no public switch for this final validator.
        # Its earlier semantic validations still run during bundling.
        from openapiart.bundler import Bundler  # pylint: disable=import-outside-toplevel

        def skip_validate_file(self):
            print("skipping OpenAPI specification validation")

        Bundler._validate_file = skip_validate_file

    os.chdir(root)
    artifact_dir = root / "artifacts"
    if artifact_dir.exists():
        shutil.rmtree(artifact_dir)
    generated_dir = root / "gosnappi"
    if generated_dir.exists():
        shutil.rmtree(generated_dir)
    python_dir = root / "snappi"
    if python_dir.exists():
        shutil.rmtree(python_dir)

    version = args.models_tag.removeprefix("v")
    art = openapiart.OpenApiArt(
        api_files=[str(openapi)], protobuf_name="otg", artifact_dir=str(artifact_dir),
        extension_prefix="snappi", generate_version_api=True,
    )
    # Upstream does not publish OpenApiArt's proto_doc/ side effect. Avoid
    # invoking protoc-gen-doc for an artifact this repository does not retain.
    art._doc_dir = None
    art.GeneratePythonSdk(
        package_name="snappi", sdk_version=version,
    ).GenerateGoSdk(
        package_dir=GO_MODULE, package_name="gosnappi", sdk_version=version,
    ).GenerateGoServer(
        module_path=GO_MODULE, models_prefix="gosnappi", models_path=GO_MODULE,
    ).GoTidy(relative_package_dir="gosnappi")
    shutil.copytree(artifact_dir / "snappi", python_dir)
    shutil.copyfile(artifact_dir / "requirements.txt", root / "requirements.txt")

    metadata = {
        "models_repository": MODELS_REPOSITORY,
        "models_tag": args.models_tag,
        "openapi_asset_url": asset_url,
        "openapi_sha256": sha256(openapi),
        "openapi_validation_skipped": args.skip_openapi_validation,
        "openapiart_repository": "fenner/openapiart",
        "openapiart_source": openapiart_source,
        "openapiart_ref": openapiart_ref,
        "openapiart_commit": openapiart_commit,
        "go_module": GO_MODULE,
        "builder_commit": git_commit_or_none(root),
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    (root / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
