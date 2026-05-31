from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest


HELPER = (
    Path(__file__).resolve().parents[1]
    / "Scripts"
    / "python"
    / "src"
    / "plugins"
    / "plugin-helper.py"
)


spec = importlib.util.spec_from_file_location("plugin_helper", HELPER)
plugin_helper = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(plugin_helper)


@pytest.mark.parametrize("plugin_id", ["safe", "safe.name", "safe-name_1"])
def test_plugin_id_accepts_safe_names(plugin_id):
    plugin_helper._validate_plugin_id(plugin_id)


@pytest.mark.parametrize("plugin_id", ["../x", "x/y", "x;y", "x y", ""])
def test_plugin_id_rejects_path_and_shell_syntax(plugin_id):
    with pytest.raises(ValueError):
        plugin_helper._validate_plugin_id(plugin_id)


@pytest.mark.parametrize("url", [
    "https://example.test/repo.git",
    "ssh://git@example.test/repo.git",
    "git@example.test:repo.git",
])
def test_repo_url_accepts_git_urls(url):
    plugin_helper._validate_repo_url(url)


@pytest.mark.parametrize("url", ["", "not a url", "javascript:alert(1)", "https:///repo"])
def test_repo_url_rejects_unsafe_shapes(url):
    with pytest.raises(ValueError):
        plugin_helper._validate_repo_url(url)


def test_plugin_service_no_longer_uses_shell_for_registry_or_install():
    service = (Path(__file__).resolve().parents[1] / "Services" / "Qdshell" / "PluginService.qml").read_text(encoding="utf-8")
    assert 'command: ["sh", "-c"' not in service
    assert "plugin-helper.py" in service
