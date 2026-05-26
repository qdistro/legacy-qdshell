"""Session-scoped pytest fixtures: nested weston + qdshell live for the whole run.

Skip the whole suite unless QDSHELL_UI_TESTS=1, so it doesn't fire from the
default qmltest workflow (which uses QT_QPA_PLATFORM=offscreen).
"""

import os
import shutil

import pytest

from . import runner

_REQUIRE_ENV = "QDSHELL_UI_TESTS"


def pytest_collection_modifyitems(config, items):
    if os.environ.get(_REQUIRE_ENV) == "1":
        return
    skip = pytest.mark.skip(reason=f"set {_REQUIRE_ENV}=1 to run UI tests")
    for item in items:
        item.add_marker(skip)


@pytest.fixture(scope="session")
def weston():
    w = runner.start_weston()
    yield w
    runner.stop_weston(w)


@pytest.fixture(scope="session")
def qdshell(weston):
    if shutil.which("qs") is None:
        pytest.skip("qs executable is not installed")
    q = runner.start_qdshell(weston)
    yield q
    runner.stop_qdshell(q)
