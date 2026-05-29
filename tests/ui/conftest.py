"""Session-scoped pytest fixtures for the agent-assisted UI harness.

Two transports are supported, selected at collection time:

  * VM transport (preferred, the qci `gui` gate path): when QDSHELL_UI_VM is
    set, the harness drives the LIVE qdshell session inside an already-running
    qdwin VM via IPC over wayland-1 and screenshots the VM framebuffer with
    `virsh screenshot`. This is the validated path — qdshell renders fine in a
    real qdwin session (the headless host nested-compositor SIGSEGVs during
    early FileView load; see
    todo/qdwin-vm/agent-ui-harness-headless-quickshell-crash.md).

  * Host transport (legacy/fallback): boots a nested headless compositor +
    qdshell on the host. Known to crash under headless Wayland on this host,
    so when no VM is provided we FAIL LOUDLY with the exact reason instead of
    silently passing on a blank framebuffer.

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


# ---------------------------------------------------------------------------
# VM transport
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def _vm_session():
    """A live qdshell VM session, or None if QDSHELL_UI_VM is unset."""
    session = runner.vm_session_from_env()
    if session is None:
        return None
    ok, reason = runner.vm_session_healthy(session)
    if not ok:
        # Loud, precise failure — never silently pass on a session that is
        # not actually qdshell (e.g. a labwc-only VM profile).
        pytest.fail(
            f"QDSHELL_UI_VM={session.vm} but no usable qdshell session: {reason}",
            pytrace=False,
        )
    return session


# ---------------------------------------------------------------------------
# Host transport (legacy fallback)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def _host_qdshell(_vm_session):
    """Host nested-compositor qdshell. Only used when no VM is provided."""
    if _vm_session is not None:
        return None
    if shutil.which("qs") is None:
        pytest.skip("qs executable is not installed")
    w = runner.start_weston()
    try:
        q = runner.start_qdshell(w)
    except Exception:
        runner.stop_weston(w)
        raise
    yield q
    runner.stop_qdshell(q)
    runner.stop_weston(w)


# ---------------------------------------------------------------------------
# Unified capture entry point used by all tests
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def capture(_vm_session, request):
    """Return a `capture(surface) -> (png_path, description)` callable.

    Routes to the VM transport when a VM is provided, else the host transport.
    """
    if _vm_session is not None:
        session = _vm_session

        def _cap(surface):
            return runner.capture_surface_vm(session, surface)

        return _cap

    # No VM: fall back to the host path. It is known to crash on headless
    # hosts, but we still try (rather than skip blindly) so a host with a
    # working nested compositor keeps working; failures surface loudly.
    host_q = request.getfixturevalue("_host_qdshell")

    def _cap(surface):
        return runner.capture_surface(host_q, surface)

    return _cap
