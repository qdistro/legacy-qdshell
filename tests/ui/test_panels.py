"""One parametrized test per slide-out panel."""

import pytest

from . import runner
from .manifests import PANEL_SURFACES, NO_IPC


@pytest.mark.parametrize("surface", PANEL_SURFACES, ids=lambda s: s.id)
def test_panel(qdshell, surface):
    if surface.open_cmd is NO_IPC:
        pytest.xfail(
            f"{surface.id}: no IPC handle in current qdshell; add one to test"
        )
    png, actual = runner.capture_surface(qdshell, surface)
    assert png.exists()
    reference = (runner.EXPECTATIONS_DIR / surface.expectation).read_text()
    verdict = runner.judge(reference, actual)
    if verdict.verdict == "SKIP":
        pytest.skip(verdict.raw)
    assert verdict.verdict == "PASS", (
        f"{surface.id} regressed.\n"
        f"  missing: {verdict.missing}\n"
        f"  extra:   {verdict.extra}\n"
        f"  judge:   {verdict.raw}\n"
        f"  png:     {png}\n"
        f"  actual described as:\n{actual}"
    )
