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


PLUGIN_ID_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")
COMPOSITE_KEY_RE = re.compile(r"^(?:[A-Fa-f0-9]{6}:)?[A-Za-z0-9_][A-Za-z0-9_.-]*$")


def _validate_repo_url(url: str) -> None:
    # F9: a plugin source is a full code-trust decision (the cloned tree is loaded
    # as live QML). Restrict to remote, host-bearing transports only — https and
    # ssh. Drop file:/git:/http: and scp-style "user@host:path" shorthand:
    #   - file:  lets `git clone` a local path (cross-silo info disclosure / a way
    #            to stage attacker-controlled content from another silo's dir);
    #   - git:/http: are unauthenticated/cleartext;
    #   - scp-style shorthand is harder to validate and widens the surface
    #     (use the explicit ssh:// form instead).
    # urlparse is not a security boundary; reject control chars outright.
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in url):
        raise ValueError("repository URL contains control characters")
    parsed = urlparse(url)
    if parsed.scheme not in ("https", "ssh"):
        raise ValueError("unsupported repository URL scheme (only https/ssh)")
    if not parsed.netloc:
        raise ValueError("repository URL is missing a host")


def _validate_plugin_id(plugin_id: str) -> None:
    # F6 (QML/Python parity): the charset regex alone admits "safe..x"; reject any
    # ".." traversal segment and all-dot ids, matching PluginRegistry.isSafePluginId.
    if (
        not PLUGIN_ID_RE.fullmatch(plugin_id)
        or ".." in plugin_id
        or set(plugin_id) == {"."}
    ):
        raise ValueError("invalid plugin id")


def _validate_composite_key(composite_key: str) -> None:
    if not COMPOSITE_KEY_RE.fullmatch(composite_key):
        raise ValueError("invalid plugin install key")
    suffix = composite_key.rsplit(":", 1)[-1]
    if ".." in suffix or set(suffix) == {"."}:
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
        "--quiet", "--", repo_url, str(temp_dir),
    ])
    _run(["git", "sparse-checkout", "set", "--no-cone", "--", checkout], cwd=temp_dir)


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
        if dest.exists():
            shutil.copytree(src, dest, symlinks=False, dirs_exist_ok=True)
        else:
            shutil.copytree(src, dest, symlinks=False)
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
