#!/usr/bin/env python3
"""qdshell plugin registry/install helper."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse


PLUGIN_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
COMPOSITE_KEY_RE = re.compile(r"^(?:[A-Fa-f0-9]{6}:)?[A-Za-z0-9_.-]+$")


def _validate_repo_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme in ("http", "https", "ssh", "git", "file"):
        if parsed.scheme != "file" and not parsed.netloc:
            raise ValueError("repository URL is missing a host")
        return
    if re.match(r"^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:.+", url):
        return
    raise ValueError("unsupported repository URL")


def _validate_plugin_id(plugin_id: str) -> None:
    if not PLUGIN_ID_RE.fullmatch(plugin_id):
        raise ValueError("invalid plugin id")


def _validate_composite_key(composite_key: str) -> None:
    if not COMPOSITE_KEY_RE.fullmatch(composite_key):
        raise ValueError("invalid plugin install key")


def _run(argv: list[str], cwd: Path | None = None) -> None:
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )


def _clone_sparse(repo_url: str, checkout: str, temp_dir: Path) -> None:
    _run([
        "git", "clone", "--filter=blob:none", "--sparse", "--depth=1",
        "--quiet", repo_url, str(temp_dir),
    ])
    _run(["git", "sparse-checkout", "set", "--no-cone", checkout], cwd=temp_dir)


def fetch_registry(repo_url: str) -> int:
    _validate_repo_url(repo_url)
    with tempfile.TemporaryDirectory(prefix="qdshell-plugin-") as tmp:
        temp_dir = Path(tmp)
        _clone_sparse(repo_url, "/registry.json", temp_dir)
        sys.stdout.buffer.write((temp_dir / "registry.json").read_bytes())
    return 0


def install_plugin(repo_url: str, plugin_id: str, plugin_dir: str) -> int:
    _validate_repo_url(repo_url)
    _validate_plugin_id(plugin_id)
    dest = Path(plugin_dir).expanduser()
    _validate_composite_key(dest.name)
    with tempfile.TemporaryDirectory(prefix="qdshell-plugin-") as tmp:
        temp_dir = Path(tmp)
        _clone_sparse(repo_url, plugin_id, temp_dir)
        src = temp_dir / plugin_id
        if not src.is_dir():
            raise FileNotFoundError(plugin_id)
        dest.parent.mkdir(parents=True, exist_ok=True)
        stage = dest.parent / (dest.name + ".tmp")
        if stage.exists():
            shutil.rmtree(stage)
        shutil.copytree(src, stage, symlinks=False)
        if dest.exists():
            shutil.rmtree(dest)
        stage.rename(dest)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    fetch = sub.add_parser("fetch-registry")
    fetch.add_argument("repo_url")
    install = sub.add_parser("install-plugin")
    install.add_argument("repo_url")
    install.add_argument("plugin_id")
    install.add_argument("plugin_dir")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "fetch-registry":
            return fetch_registry(args.repo_url)
        if args.cmd == "install-plugin":
            return install_plugin(args.repo_url, args.plugin_id, args.plugin_dir)
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
