"""One parametrized test per Settings tab."""

from pathlib import Path

import pytest

from . import runner
from .manifests import SETTINGS_SURFACES


@pytest.mark.parametrize("surface", SETTINGS_SURFACES, ids=lambda s: s.id)
def test_settings_tab(capture, surface):
    png, actual = capture(surface)
    assert png.exists(), f"no screenshot for {surface.id}"
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
