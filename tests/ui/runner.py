"""Primitives for the agent-assisted UI test harness.

Boots a nested headless weston, runs qdshell against it, exposes IPC + screenshot
+ vision-LLM + LLM-judge helpers.

Design notes:
  * Headless weston is a wlroots-independent path that works on any
    distro that ships weston; it does not require a real GPU or seat,
    so this whole rig can run in a CI container too.
  * `weston-screenshooter` is shipped with weston and uses weston's
    debug screenshot protocol — it only works when weston is started
    with `--debug`. We always pass `--debug`.
  * Vision uses the local Codex CLI when available, matching the qdistro
    GUI scenario agent setup. With no LLM backend, the harness still boots,
    screenshots, and writes them under artifacts/ so a human reviewer can
    compare manually.
"""

from __future__ import annotations

import base64
import contextlib
import dataclasses
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Iterator, Optional, Union

QDSHELL_ROOT = Path(__file__).resolve().parents[2]
UI_TESTS_ROOT = Path(__file__).resolve().parent
EXPECTATIONS_DIR = UI_TESTS_ROOT / "expectations"
ARTIFACTS_DIR = UI_TESTS_ROOT / "artifacts"

# ---------------------------------------------------------------------------
# Nested headless compositor
#
# qdshell uses wlr-layer-shell for every panel/bar surface. Weston deliberately
# does not implement layer-shell, so we must use a wlroots-based compositor.
# We probe for one in priority order.
#
# Recommended installs (any one is sufficient):
#   sudo zypper in sway        # openSUSE
#   sudo zypper in labwc
#   sudo zypper in cage
# ---------------------------------------------------------------------------

# (compositor name on PATH, layer-shell support?, weston-screenshooter compatible?)
# weston is included as a fallback for non-layer-shell sanity checks only.
_COMPOSITOR_CANDIDATES = ["sway", "labwc", "cage", "wayfire", "river", "weston"]


@dataclasses.dataclass
class Compositor:
    name: str                          # "sway" | "labwc" | ...
    socket_name: str
    proc: subprocess.Popen
    runtime_dir: str
    log_path: Path

    @property
    def supports_layer_shell(self) -> bool:
        return self.name != "weston"

    def env(self) -> dict[str, str]:
        e = os.environ.copy()
        e["WAYLAND_DISPLAY"] = self.socket_name
        e["XDG_RUNTIME_DIR"] = self.runtime_dir
        e.pop("DISPLAY", None)
        return e


# Back-compat alias for callers that imported the old name.
Weston = Compositor


def _free_socket_name(runtime_dir: str) -> str:
    for i in range(10, 99):
        name = f"wayland-qdshell-test-{i}"
        if not Path(runtime_dir, name).exists():
            return name
    raise RuntimeError("no free wayland socket name")


def _pick_compositor() -> str:
    for c in _COMPOSITOR_CANDIDATES:
        if shutil.which(c):
            return c
    raise RuntimeError(
        "No nested compositor binary on PATH. qdshell needs wlr-layer-shell; "
        "install one of: sway, labwc, cage. Tried: "
        + ", ".join(_COMPOSITOR_CANDIDATES)
    )


_MINIMAL_SWAY_CONFIG = """\
# Minimal sway config for qdshell UI tests — no bar, no autostart.
default_border none
default_floating_border none
exec_always true
"""


def _make_solid_png(width: int, height: int, rgba: tuple[int, int, int, int]) -> bytes:
    """Produce a valid PNG of (width × height) filled with rgba."""
    import struct
    import zlib

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    pixel = bytes(rgba)
    raw = b"".join(b"\x00" + pixel * width for _ in range(height))
    idat_data = zlib.compress(raw, 9)

    def chunk(name: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(name + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", crc)

    return sig + chunk(b"IHDR", ihdr_data) + chunk(b"IDAT", idat_data) + chunk(b"IEND", b"")


def _write_minimal_config(name: str, runtime_dir: str) -> Optional[str]:
    """Some compositors will autostart waybar/swaync/etc. from the system
    config unless we hand them a minimal one. Returns the path or None.
    """
    if name == "sway":
        p = Path(runtime_dir, "sway.config")
        p.write_text(_MINIMAL_SWAY_CONFIG)
        return str(p)
    # labwc reads ~/.config/labwc/{rc.xml,autostart,environment}; we set
    # XDG_CONFIG_HOME to a scratch dir elsewhere, so no override needed here.
    return None


def _compositor_cmd(name: str, width: int, height: int,
                    config_path: Optional[str]) -> tuple[list[str], dict]:
    """Return (argv, extra_env) for the chosen compositor's headless mode.

    For wlroots compositors we DO NOT preset WAYLAND_DISPLAY — they pick their
    own socket name. Caller detects it by polling runtime_dir.
    """
    wlroots_env = {
        "WLR_BACKENDS": "headless",
        "WLR_LIBINPUT_NO_DEVICES": "1",
        "WLR_HEADLESS_OUTPUTS": "1",
        "WLR_RENDERER": "pixman",       # no GPU needed
        # Stop wlroots from inheriting the host's session bus / pid1 stuff.
        "DBUS_SESSION_BUS_ADDRESS": "",
    }
    if name == "sway":
        argv = ["sway", "--unsupported-gpu"]
        if config_path:
            argv += ["-c", config_path]
        return (argv, wlroots_env)
    if name == "labwc":
        return (["labwc"], wlroots_env)
    if name == "cage":
        # cage requires a child program; we use a no-op holder.
        return (["cage", "--", "sleep", "infinity"], wlroots_env)
    if name == "wayfire":
        return (["wayfire"], wlroots_env)
    if name == "river":
        return (["river"], wlroots_env)
    if name == "weston":
        # weston honors --socket; pre-pick its name.
        return ([], {})  # handled separately
    raise RuntimeError(f"unknown compositor {name}")


def _detect_wayland_socket(runtime_dir: str, before: set[str], deadline: float) -> Optional[str]:
    """Poll runtime_dir for a freshly-created wayland-* socket."""
    while time.time() < deadline:
        now = set(p.name for p in Path(runtime_dir).glob("wayland-*")
                  if not p.name.endswith(".lock"))
        new = now - before
        if new:
            # Pick the lexicographically smallest new one (usually wayland-1).
            return sorted(new)[0]
        time.sleep(0.1)
    return None


def start_compositor(width: int = 1920, height: int = 1200,
                     prefer: Optional[str] = None) -> Compositor:
    """Start a nested headless compositor. Returns when its socket is live."""
    name = prefer or _pick_compositor()
    runtime_dir = tempfile.mkdtemp(prefix="qdshell-uitest-")
    os.chmod(runtime_dir, 0o700)
    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)

    # Snapshot current sockets so we can spot the new one.
    before = set(p.name for p in Path(runtime_dir).glob("wayland-*")
                 if not p.name.endswith(".lock"))

    config_path = _write_minimal_config(name, runtime_dir)

    if name == "weston":
        # weston gets a pre-picked socket.
        sock = _free_socket_name(runtime_dir)
        argv = ["weston", "--backend=headless", "--renderer=pixman",
                "--shell=desktop", "--debug",
                f"--width={width}", f"--height={height}",
                f"--socket={sock}", "--idle-time=0"]
        extra_env: dict[str, str] = {}
    else:
        argv, extra_env = _compositor_cmd(name, width, height, config_path)
        sock = None  # detected after launch

    log_path = ARTIFACTS_DIR / f"{name}.log"
    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = runtime_dir
    # Scratch XDG_CONFIG_HOME so labwc / wayfire / etc. don't load user config.
    scratch_cfg = Path(runtime_dir, "xdg-config")
    scratch_cfg.mkdir()
    env["XDG_CONFIG_HOME"] = str(scratch_cfg)
    env.update(extra_env)
    if sock is not None:
        env["WAYLAND_DISPLAY"] = sock
    else:
        env.pop("WAYLAND_DISPLAY", None)

    log_f = open(log_path, "wb")
    proc = subprocess.Popen(
        argv, env=env, stdout=log_f, stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    deadline = time.time() + 15
    if sock is not None:
        socket_path = Path(runtime_dir, sock)
        while time.time() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(
                    f"{name} exited early (rc={proc.returncode}); see {log_path}"
                )
            if socket_path.exists():
                return Compositor(name, sock, proc, runtime_dir, log_path)
            time.sleep(0.1)
        proc.terminate()
        raise RuntimeError(f"{name} did not create socket within 15s; see {log_path}")
    else:
        detected = _detect_wayland_socket(runtime_dir, before, deadline)
        if detected is None:
            if proc.poll() is not None:
                proc_rc = proc.returncode
            else:
                proc.terminate()
                proc_rc = None
            raise RuntimeError(
                f"{name} did not create a wayland socket within 15s "
                f"(proc_rc={proc_rc}); see {log_path}"
            )
        return Compositor(name, detected, proc, runtime_dir, log_path)


# Back-compat alias.
def start_weston(width: int = 1920, height: int = 1200) -> Compositor:
    return start_compositor(width=width, height=height)


def stop(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)


def stop_compositor(c: Compositor) -> None:
    stop(c.proc)
    shutil.rmtree(c.runtime_dir, ignore_errors=True)


# Back-compat alias.
def stop_weston(w: Compositor) -> None:
    stop_compositor(w)


# ---------------------------------------------------------------------------
# qdshell instance
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class Qdshell:
    proc: subprocess.Popen
    weston: Compositor                 # name kept for back-compat; any compositor
    config_home: str
    log_path: Path


def _resolve_qml_import_path() -> Optional[str]:
    """Build a QML_IMPORT_PATH entry pointing at the local qml-plugin build.

    qdshell's QML imports `Qdistro.Qdwin 1.0`, served by
    `<repo>/qml-plugin/libqdistro-qdwin.so` + qmldir. Qt's QML loader
    looks for `<import-path>/Qdistro/Qdwin/qmldir`, so we materialise
    that layout under `<repo>/build/qml-staged/` and return its parent.
    Returns None when the .so has not been built — the test will then
    surface the usual ImportError instead of silently passing.
    """
    plugin_so = QDSHELL_ROOT / "build" / "qml-plugin" / "libqdistro-qdwin.so"
    qmldir_src = QDSHELL_ROOT / "qml-plugin" / "qmldir"
    if not plugin_so.exists() or not qmldir_src.exists():
        return None
    stage_root = QDSHELL_ROOT / "build" / "qml-staged"
    target_dir = stage_root / "Qdistro" / "Qdwin"
    target_dir.mkdir(parents=True, exist_ok=True)
    # Use symlinks so an incremental rebuild of the .so is picked up
    # without re-running the runner; relink defensively each call.
    for src, name in ((plugin_so, plugin_so.name), (qmldir_src, "qmldir")):
        dst = target_dir / name
        try:
            if dst.is_symlink() or dst.exists():
                dst.unlink()
            dst.symlink_to(src)
        except OSError:
            # Filesystem doesn't support symlinks (rare); fall back to copy.
            shutil.copy2(src, dst)
    return str(stage_root)


def start_qdshell(weston: Compositor, *, settle_seconds: float = 4.0) -> Qdshell:
    """Launch qs against the given nested compositor.

    A scratch HOME is used so the test never reads/writes the user's real
    qdshell config. We also seed Pictures/Wallpapers/ with a 1×1 placeholder
    image so the Wallpaper panel renders its grid instead of an empty
    file-browser state.
    """
    home = tempfile.mkdtemp(prefix="qdshell-uitest-home-")
    config_home = str(Path(home, ".config"))
    Path(config_home).mkdir()
    wallpapers = Path(home, "Pictures", "Wallpapers")
    wallpapers.mkdir(parents=True)
    # Generate a real 256×256 solid-color PNG so qdshell's wallpaper panel
    # actually produces a thumbnail. A 1×1 placeholder gets rendered as the
    # "no preview" icon, which makes the panel look broken in screenshots.
    (wallpapers / "seed.png").write_bytes(_make_solid_png(256, 256, (76, 86, 160, 255)))

    log_path = ARTIFACTS_DIR / "qdshell.log"
    env = weston.env()
    env["HOME"] = home
    env["XDG_CONFIG_HOME"] = config_home
    env["QT_QPA_PLATFORM"] = "wayland"
    env.setdefault("QS_LOG_LEVEL", "info")
    staged = _resolve_qml_import_path()
    if staged is not None:
        existing = env.get("QML_IMPORT_PATH", "")
        env["QML_IMPORT_PATH"] = staged + (
            (":" + existing) if existing else ""
        )
    cmd = ["qs", "--path", str(QDSHELL_ROOT), "--allow-duplicate"]
    log_f = open(log_path, "wb")
    proc = subprocess.Popen(
        cmd, env=env, stdout=log_f, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    # qdshell needs a moment to load its 102K LOC of QML + register IPC.
    deadline = time.time() + settle_seconds
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(
                f"qs exited early (rc={proc.returncode}); see {log_path}"
            )
        time.sleep(0.2)
    return Qdshell(proc, weston, config_home, log_path)


def stop_qdshell(q: Qdshell) -> None:
    stop(q.proc)
    # config_home is now under a scratch HOME; clean the whole HOME.
    home = str(Path(q.config_home).parent)
    shutil.rmtree(home, ignore_errors=True)


# ---------------------------------------------------------------------------
# IPC
# ---------------------------------------------------------------------------

def ipc(q: Qdshell, *args: str, timeout: float = 5.0) -> subprocess.CompletedProcess:
    """Send a `qs ipc call` to the nested qdshell.

    We target by --pid because qs launched via --path has no config name and
    the default `qs ipc` lookup would otherwise try $XDG_CONFIG_HOME/quickshell/default.
    """
    cmd = ["qs", "ipc", "--pid", str(q.proc.pid), "call", *args]
    res = subprocess.run(
        cmd, env=q.weston.env(), capture_output=True, text=True, timeout=timeout,
    )
    if res.returncode != 0:
        # Surface IPC failures loudly; silent IPC = silent test corruption.
        raise RuntimeError(
            f"qs ipc call {' '.join(args)} failed (rc={res.returncode})\n"
            f"  stdout: {res.stdout.strip()}\n"
            f"  stderr: {res.stderr.strip()}"
        )
    return res


# ---------------------------------------------------------------------------
# VM session transport
#
# The host headless nested-compositor path (above) cannot screenshot tabs:
# quickshell SIGSEGVs during the early FileView settings load when the
# headless Wayland output drops (see
# todo/qdwin-vm/agent-ui-harness-headless-quickshell-crash.md). qdshell
# renders fine in a REAL qdwin VM session, so the qci `gui` gate runs this
# harness against the live VM session it already acquired.
#
# Transport:
#   * IPC tab-driving runs INSIDE the VM via vm-exec -> qemu-guest-agent,
#     as the admin user against the live qdshell quickshell instance on
#     wayland-1. We use `qs ipc -p /usr/share/quickshell/qdshell call ...`,
#     matching the deployed qdshell.service ExecStart.
#   * Screenshots are captured from the HOST with `virsh screenshot`, which
#     grabs the VM's framebuffer (the qdwin/weston output) — the validated
#     pattern from qdwin/tests/gui (qdwin_screenshot). No in-VM screenshot
#     tool (grim/weston-screenshooter) is required.
#   * Codex describe/judge still run on the HOST against the pulled-back PNG.
#
# SECURITY: every argument that reaches the VM's `/bin/sh -c` (via
# qemu-guest-agent) MUST be from a fixed allowlist. IPC verbs/targets/tab
# names come only from manifests.SETTINGS_TABS and the hard-coded panel
# commands; we additionally hard-validate each token against _IPC_TOKEN_RE
# before it is ever shipped, so an out-of-band manifest edit cannot smuggle
# shell metacharacters through. The command body itself is base64-encoded
# (the vm-script idiom) so nothing dynamic is interpolated into the guest
# `sh -c` string except an opaque ASCII token plus literal command text.
# ---------------------------------------------------------------------------

# qdshell is deployed at this path inside the VM (deploy/qdshell.service:
# `qs -p /usr/share/quickshell/qdshell`). IPC must target the same config.
VM_QDSHELL_PATH = "/usr/share/quickshell/qdshell"
VM_WAYLAND_DISPLAY = "wayland-1"
VM_XDG_RUNTIME_DIR = "/run/user/1000"
VM_USER = "admin"

# Defense-in-depth: only safe shell-free tokens may reach the guest sh -c.
_IPC_TOKEN_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_.:=/-]*\Z")


@dataclasses.dataclass
class VMSession:
    """A handle to a live qdshell session inside a qdwin VM.

    `vm` is the libvirt domain name (already acquired/validated by qci).
    `vm_exec` / `virsh` are the host-side tool invocations (lists of argv
    tokens) used to reach the guest and grab its framebuffer.
    """
    vm: str
    vm_exec: list[str]
    virsh: list[str]


def _validate_ipc_token(tok: str) -> str:
    """Reject any IPC arg that isn't a plain allowlisted token.

    Tab names / IPC verbs are developer-authored constants (manifests.py),
    never user input — but they get funnelled through qemu-guest-agent's
    `/bin/sh -c`, so we refuse anything containing shell metacharacters as a
    hard backstop against an accidental unsafe manifest entry.
    """
    if not isinstance(tok, str) or not _IPC_TOKEN_RE.match(tok):
        raise ValueError(
            f"refusing to drive unsafe IPC token {tok!r}: IPC args must match "
            f"{_IPC_TOKEN_RE.pattern} (developer-authored manifest constants only)"
        )
    return tok


def _vm_run_script(session: VMSession, script: str, *, timeout: float = 60.0
                   ) -> subprocess.CompletedProcess:
    """Run a shell script inside the VM, base64-wrapped (the vm-script idiom).

    The script body is base64-encoded on the host so nothing in it is
    interpolated into the guest's `sh -c` — qemu-guest-agent only ever sees
    `echo <opaque-ascii> | base64 -d | bash`. The caller is responsible for
    building `script` from validated tokens only.
    """
    b64 = base64.b64encode(script.encode()).decode("ascii")
    guest_cmd = f"echo {b64} | base64 -d | bash"
    return subprocess.run(
        session.vm_exec + [session.vm, guest_cmd],
        capture_output=True, text=True, timeout=timeout,
    )


def ipc_vm(session: VMSession, *args: str, timeout: float = 30.0) -> subprocess.CompletedProcess:
    """Send a `qs ipc call` to the qdshell instance running inside the VM.

    Runs as the admin user against wayland-1, targeting the deployed qdshell
    config path. Every arg is validated against the token allowlist first.
    """
    safe_args = [_validate_ipc_token(a) for a in args]
    # Build the guest command from validated tokens; safe to embed in the
    # base64'd script body. `qs ipc -p <path> call <args...>`.
    arg_str = " ".join(safe_args)
    script = (
        f"set -eu\n"
        f"runuser -u {VM_USER} -- env "
        f"XDG_RUNTIME_DIR={VM_XDG_RUNTIME_DIR} WAYLAND_DISPLAY={VM_WAYLAND_DISPLAY} "
        f"qs ipc -p {VM_QDSHELL_PATH} call {arg_str}\n"
    )
    res = _vm_run_script(session, script, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(
            f"VM ipc call {' '.join(safe_args)} failed (rc={res.returncode})\n"
            f"  stdout: {res.stdout.strip()}\n"
            f"  stderr: {res.stderr.strip()}"
        )
    return res


def _convert_ppm_to_png(ppm_path: Path, png_path: Path) -> None:
    """Convert a virsh-screenshot PPM to PNG so codex --image accepts it."""
    if shutil.which("pnmtopng"):
        with open(png_path, "wb") as out:
            res = subprocess.run(["pnmtopng", str(ppm_path)], stdout=out,
                                 stderr=subprocess.PIPE, text=True, timeout=30)
        if res.returncode == 0 and png_path.stat().st_size > 0:
            return
    for tool in ("magick", "convert"):
        if shutil.which(tool):
            res = subprocess.run([tool, str(ppm_path), str(png_path)],
                                 capture_output=True, text=True, timeout=30)
            if res.returncode == 0 and png_path.exists() and png_path.stat().st_size > 0:
                return
    # Last resort: Pillow.
    try:
        from PIL import Image
        Image.open(ppm_path).save(png_path)
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            f"could not convert {ppm_path} to PNG (no pnmtopng/convert/magick/PIL): {exc}"
        )
    if not (png_path.exists() and png_path.stat().st_size > 0):
        raise RuntimeError(
            f"PPM->PNG conversion of {ppm_path} produced no usable PNG"
        )


def screenshot_vm(session: VMSession, out_path: Path) -> Path:
    """Capture the VM's framebuffer (the live qdwin session) to a PNG.

    Uses host-side `virsh screenshot`, which writes a PPM; we convert to PNG.
    This is the same mechanism qdwin/tests/gui uses (qdwin_screenshot).
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)
    ppm_path = out_path.with_suffix(".ppm")
    res = subprocess.run(
        session.virsh + ["screenshot", session.vm, str(ppm_path)],
        capture_output=True, text=True, timeout=30,
    )
    if res.returncode != 0 or not ppm_path.exists():
        raise RuntimeError(
            f"virsh screenshot {session.vm} failed (rc={res.returncode}): "
            f"{res.stderr.strip() or res.stdout.strip()}"
        )
    _convert_ppm_to_png(ppm_path, out_path)
    with contextlib.suppress(OSError):
        ppm_path.unlink()
    return out_path


def capture_surface_vm(session: VMSession, surface, *, settle: float = 1.2
                       ) -> tuple[Path, str]:
    """VM analogue of capture_surface: open via in-VM IPC, virsh-screenshot, describe."""
    from .manifests import NO_IPC

    png_path = ARTIFACTS_DIR / f"{surface.id}.png"

    if surface.open_cmd is NO_IPC:
        raise RuntimeError(
            f"{surface.id} has no IPC handle; cannot drive automatically"
        )
    if surface.open_cmd is not None:
        ipc_vm(session, *surface.open_cmd)
        time.sleep(settle)

    screenshot_vm(session, png_path)
    description = describe(png_path)

    if surface.close_cmd is not None and surface.close_cmd is not NO_IPC:
        with contextlib.suppress(Exception):
            ipc_vm(session, *surface.close_cmd)
            time.sleep(0.4)

    return png_path, description


def vm_session_from_env() -> Optional[VMSession]:
    """Build a VMSession from QDSHELL_UI_VM / tool-path env, or None.

    qci sets QDSHELL_UI_VM=<domain>. VM_TOOLS / VIRSH overrides let the gate
    point at the exact vm-exec script and virsh connection it already uses.
    """
    vm = os.environ.get("QDSHELL_UI_VM", "").strip()
    if not vm:
        return None
    if not _IPC_TOKEN_RE.match(vm):
        raise RuntimeError(
            f"QDSHELL_UI_VM={vm!r} is not a valid libvirt domain name "
            f"(must match {_IPC_TOKEN_RE.pattern})"
        )
    vm_exec_path = os.environ.get("QDSHELL_UI_VM_EXEC", "").strip()
    if not vm_exec_path:
        raise RuntimeError(
            "QDSHELL_UI_VM is set but QDSHELL_UI_VM_EXEC (path to scripts/vm/vm-exec) is not"
        )
    if not (Path(vm_exec_path).is_file() and os.access(vm_exec_path, os.X_OK)):
        raise RuntimeError(f"QDSHELL_UI_VM_EXEC={vm_exec_path!r} is not an executable file")
    virsh_cmd = os.environ.get("QDSHELL_UI_VIRSH", "virsh -c qemu:///session").split()
    return VMSession(vm=vm, vm_exec=[vm_exec_path], virsh=virsh_cmd)


def vm_session_healthy(session: VMSession) -> tuple[bool, str]:
    """Probe that a live qdshell session is reachable in the VM.

    Returns (ok, reason). ok=False means the harness must FAIL/skip loudly
    rather than capture a blank/labwc framebuffer and silently pass.
    """
    # 1. wayland-1 socket present (qdwin/weston session up).
    script = (
        f"set -eu\n"
        f"test -S {VM_XDG_RUNTIME_DIR}/{VM_WAYLAND_DISPLAY}\n"
    )
    res = _vm_run_script(session, script, timeout=30)
    if res.returncode != 0:
        return (False, f"{VM_XDG_RUNTIME_DIR}/{VM_WAYLAND_DISPLAY} not present "
                       f"(no live qdwin session in VM {session.vm}); "
                       f"stderr: {res.stderr.strip()}")
    # 2. qdshell IPC answers — proves the quickshell config is the deployed
    #    qdshell (not labwc/another shell) and IPC is live.
    try:
        ipc_vm(session, "bar", "showBar", timeout=30)
    except RuntimeError as exc:
        return (False,
                f"qdshell IPC not reachable in VM {session.vm} "
                f"(session may be labwc-only, not qdshell): {exc}")
    return (True, "qdshell session live")


# ---------------------------------------------------------------------------
# Screenshot
# ---------------------------------------------------------------------------

def screenshot(q: Qdshell, out_path: Path) -> Path:
    """Capture the compositor's framebuffer to a PNG.

    wlroots-based compositors expose wlr-screencopy → use `grim`.
    Weston exposes its own debug screenshot protocol → use
    `weston-screenshooter`.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if q.weston.supports_layer_shell:
        # wlroots family: grim
        if not shutil.which("grim"):
            raise RuntimeError(
                "grim not installed (needed to screenshot wlroots compositors). "
                "Install with your package manager (e.g. `sudo zypper in grim`)."
            )
        res = subprocess.run(
            ["grim", str(out_path)],
            env=q.weston.env(),
            capture_output=True, text=True, timeout=10,
        )
        if res.returncode != 0:
            raise RuntimeError(
                f"grim failed (rc={res.returncode}): {res.stderr}"
            )
        return out_path

    # weston fallback
    res = subprocess.run(
        ["weston-screenshooter"],
        env=q.weston.env(),
        cwd=str(out_path.parent),
        capture_output=True, text=True, timeout=10,
    )
    if res.returncode != 0:
        raise RuntimeError(
            f"weston-screenshooter failed (rc={res.returncode}): {res.stderr}"
        )
    candidates = sorted(
        out_path.parent.glob("wayland-screenshot-*.png"),
        key=lambda p: p.stat().st_mtime,
    )
    if not candidates:
        raise RuntimeError(
            "weston-screenshooter reported success but produced no PNG"
        )
    candidates[-1].rename(out_path)
    return out_path


# ---------------------------------------------------------------------------
# Vision: describe(image) -> bullet list of what's visible
# ---------------------------------------------------------------------------

_DESCRIBE_PROMPT = """You are looking at a screenshot of a desktop shell UI.

Describe ONLY what is actually visible. Do NOT speculate about what a similar
UI might typically contain.

Cover, as bullet points:
  - The header/title text shown at the top of the visible panel or tab.
  - Visible labelled controls: button labels, toggle states (on/off),
    slider values if numeric values are shown, dropdown current values.
  - Visible section headings inside the panel.
  - Notable icons (by their general subject: "battery icon", "wifi icon", etc.).
  - Approximate layout: tabs along which side; content arranged in rows/cards/columns.

Constraints:
  - Be concise. Under ~150 words total.
  - Do not invent text you cannot read.
  - If the panel appears empty / shell still loading, say so explicitly.
"""


def describe(image_path: Path) -> str:
    """Send PNG to a vision LLM; return the textual description.

    Uses the local Codex CLI, unless QDSHELL_UI_NO_CODEX=1 is set. Falls
    back to `pi` when available. Returns "" when no backend is available;
    callers should treat that as "describe step skipped".
    """
    if shutil.which("codex") and os.environ.get("QDSHELL_UI_NO_CODEX") != "1":
        return _describe_with_codex(image_path)
    if shutil.which("pi") and os.environ.get("QDSHELL_UI_NO_PI") != "1":
        return _describe_with_pi(image_path)
    return ""


def _run_codex(prompt: str, image_path: Optional[Path] = None) -> str:
    with tempfile.TemporaryDirectory(prefix="qdshell-codex-") as tmp:
        output_path = Path(tmp) / "last-message.txt"
        cmd = [
            "codex", "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            "--sandbox", "danger-full-access",
            "--cd", str(QDSHELL_ROOT),
            "--ephemeral",
            "--output-last-message", str(output_path),
        ]
        if image_path is not None:
            cmd.extend(["--image", str(image_path)])
        cmd.append(prompt)
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=180,
            )
        except (subprocess.TimeoutExpired, OSError):
            return ""
        if output_path.exists():
            return output_path.read_text(errors="replace").strip()
        if result.returncode != 0:
            return ""
        return result.stdout.strip()


def _describe_with_codex(image_path: Path) -> str:
    return _run_codex(_DESCRIBE_PROMPT, image_path=image_path)


def _describe_with_pi(image_path: Path) -> str:
    """Vision via local pi CLI + qwen3.6-plus. See memory: reference-pi-vision-fallback."""
    try:
        result = subprocess.run(
            ["pi", "--print", "--provider", "qwen", "--model", "qwen3.6-plus",
             f"@{image_path}", _DESCRIBE_PROMPT],
            capture_output=True, text=True, timeout=120,
        )
    except (subprocess.TimeoutExpired, OSError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# Judge: compare observed description vs golden expectation
# ---------------------------------------------------------------------------

_JUDGE_PROMPT_TEMPLATE = """A UI regression test captured a description of a
qdshell surface. Compare it against the reference description authored by a
developer. The reference lists what MUST be visible; the actual description
is what the screenshot-describer reported.

REFERENCE (what must be present):
---
{reference}
---

ACTUAL (what was observed in the latest screenshot):
---
{actual}
---

Decide: do all the load-bearing reference elements appear in the actual? Cosmetic
phrasing differences are fine. A reference bullet is satisfied if its meaning is
present in the actual, even with different wording. A reference bullet is
violated if its element is clearly absent or contradicted.

Reply in this exact format:
  MISSING: <bullet, or 'none'>
  MISSING: <bullet, or 'none'>
  ...
  EXTRA:   <bullet, or 'none'>     (only flag if it suggests a real regression)
  VERDICT: PASS or FAIL
"""


@dataclasses.dataclass
class JudgeResult:
    verdict: str          # "PASS" / "FAIL" / "SKIP"
    raw: str              # full judge response
    missing: list[str]
    extra: list[str]


def judge(reference: str, actual: str) -> JudgeResult:
    """LLM-as-judge: does `actual` cover everything `reference` requires?

    Uses the local Codex CLI, unless QDSHELL_UI_NO_CODEX=1. Falls back to
    `pi` when available.
    """
    if not actual.strip():
        return JudgeResult("SKIP", "(empty actual description)", [], [])
    prompt = _JUDGE_PROMPT_TEMPLATE.format(
        reference=reference.strip(), actual=actual.strip(),
    )
    raw = ""
    if shutil.which("codex") and os.environ.get("QDSHELL_UI_NO_CODEX") != "1":
        raw = _run_codex(prompt)
    if not raw and shutil.which("pi") and os.environ.get("QDSHELL_UI_NO_PI") != "1":
        raw = _judge_with_pi(prompt)
    if not raw:
        return JudgeResult("SKIP", "(no judge backend available)", [], [])
    verdict = "FAIL"
    missing, extra = [], []
    for line in raw.splitlines():
        s = line.strip()
        if s.upper().startswith("VERDICT:"):
            verdict = s.split(":", 1)[1].strip().upper()
        elif s.upper().startswith("MISSING:"):
            v = s.split(":", 1)[1].strip()
            if v and v.lower() != "none":
                missing.append(v)
        elif s.upper().startswith("EXTRA:"):
            v = s.split(":", 1)[1].strip()
            if v and v.lower() != "none":
                extra.append(v)
    return JudgeResult(verdict, raw, missing, extra)


def _judge_with_pi(prompt: str) -> str:
    try:
        result = subprocess.run(
            ["pi", "--print", "--provider", "qwen", "--model", "qwen3.6-plus", prompt],
            capture_output=True, text=True, timeout=120,
        )
    except (subprocess.TimeoutExpired, OSError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# Convenience: one-shot capture for a surface
# ---------------------------------------------------------------------------

def capture_surface(q: Qdshell, surface, *, settle: float = 0.8) -> tuple[Path, str]:
    """Open the surface via IPC, wait, screenshot, describe. Returns (png_path, description)."""
    from .manifests import NO_IPC

    png_path = ARTIFACTS_DIR / f"{surface.id}.png"

    if surface.open_cmd is NO_IPC:
        raise RuntimeError(
            f"{surface.id} has no IPC handle; cannot drive automatically"
        )
    if surface.open_cmd is not None:
        ipc(q, *surface.open_cmd)
        time.sleep(settle)

    screenshot(q, png_path)
    description = describe(png_path)

    # Cleanup: close panel so next test starts clean. Best-effort.
    if surface.close_cmd is not None and surface.close_cmd is not NO_IPC:
        with contextlib.suppress(Exception):
            ipc(q, *surface.close_cmd)
            time.sleep(0.3)

    return png_path, description
