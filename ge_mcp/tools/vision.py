"""See the editor: screenshots (engine render or OS window capture), camera
control, and the editor log (where print() and script errors go)."""

import re
import subprocess
import time

from mcp.server.fastmcp import Image

from ..bridge import bridge, GE_APPDATA
from ..helpers import call_helper, int_or_str  # int_or_str used by camera tools

_WINDOW_CAPTURE_PS = r"""
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class GEWin {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
}
"@
[void][GEWin]::SetProcessDPIAware()
$p = Get-Process | Where-Object { $_.MainWindowTitle -like '*GIANTS Editor*' } | Select-Object -First 1
if ($null -eq $p) { Write-Output 'NOWINDOW'; exit 1 }
$r = New-Object GEWin+RECT
[void][GEWin]::GetWindowRect($p.MainWindowHandle, [ref]$r)
$w = $r.R - $r.L; $h = $r.B - $r.T
if ($w -le 0 -or $h -le 0) { Write-Output 'BADRECT'; exit 1 }
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$g.Dispose()
$maxW = __MAXW__
if ($w -gt $maxW) {
  $h2 = [int]($h * $maxW / $w)
  $small = New-Object System.Drawing.Bitmap($bmp, $maxW, $h2)
  $bmp.Dispose(); $bmp = $small
}
$bmp.Save('__OUT__', [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ('OK ' + $w + 'x' + $h)
"""


def viewport_screenshot(mode: str = "window", width: int = 1280, height: int = 720):
    """Grab an image of the GIANTS Editor so Claude can SEE the scene.

    mode='window' (default): OS capture of the whole editor window -- shows
    everything the user sees, INCLUDING splines, gizmos, selection outlines and
    UI panels. The window must be visible on screen (not minimized).
    mode='render': the engine's own renderScreenshot of the active camera --
    clean meshes/terrain only (NO splines or UI), works even with the editor in
    the background, and honors the requested width/height.
    """
    if mode == "render":
        shot = GE_APPDATA / "mcp_shot.png"
        try:
            shot.unlink()
        except FileNotFoundError:
            pass
        aspect = float(width) / float(height)
        lua = ('renderScreenshot("{p}", {w}, {h}, {a}, "srgb", 0, 0.0, 0.0, 0.0, 0.0, 3, 12, true) '
               'return "rendered"').format(p=str(shot).replace("\\", "/"), w=int(width), h=int(height), a=aspect)
        r = bridge(lua, timeout=30.0)
        if not r["ok"]:
            return "[ERROR] renderScreenshot failed:\n" + r["result"]
        deadline = time.time() + 8.0
        while time.time() < deadline:
            if shot.is_file() and shot.stat().st_size > 0:
                break
            time.sleep(0.1)
        if not shot.is_file() or shot.stat().st_size == 0:
            return "[ERROR] renderScreenshot reported ok but no file appeared at " + str(shot)
        return Image(data=shot.read_bytes(), format="png")

    # mode == "window": OS capture (shows splines/gizmos/UI)
    out = GE_APPDATA / "mcp_window.png"
    try:
        out.unlink()
    except FileNotFoundError:
        pass
    ps = _WINDOW_CAPTURE_PS.replace("__OUT__", str(out)).replace("__MAXW__", str(max(320, min(int(width), 1600))))
    try:
        proc = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                              capture_output=True, text=True, timeout=30)
    except Exception as exc:
        return "[ERROR] window capture failed to run: " + str(exc)
    marker = (proc.stdout or "").strip()
    if "NOWINDOW" in marker:
        return "[ERROR] no visible 'GIANTS Editor' window found (is it running and not minimized?)"
    if not out.is_file() or out.stat().st_size == 0:
        return ("[ERROR] window capture produced no image. PowerShell said:\n"
                + (proc.stdout or "") + (proc.stderr or ""))
    return Image(data=out.read_bytes(), format="png")


def camera_look(target: str = "", x: float = None, y: float = None, z: float = None,
                distance: float = 0.0, yaw_deg: float = 45.0,
                pitch_deg: float = 35.0) -> str:
    """Aim the active viewport camera at a node (by id/name) or world position,
    then take a viewport_screenshot to actually see it.

    distance<=0 auto-frames from the target's bounding sphere. yaw_deg is the
    compass direction the camera sits at, pitch_deg the down-angle."""
    return call_helper("cameraLook", {
        "target": int_or_str(target) if target else None,
        "x": x, "y": y, "z": z, "distance": distance,
        "yawDeg": yaw_deg, "pitchDeg": pitch_deg,
    })


_LOG_STATE = {"offset": None}


def read_log(lines: int = 60, mode: str = "new") -> str:
    """Read the editor's log (editor_log.txt) -- where print() output and native
    'Script error in X' lines actually go.

    mode='new' (default): only lines appended since the previous read_log call
    (first call behaves like tail). mode='tail': last `lines` lines regardless.
    mode='errors': last `lines` lines matching error/warning patterns.
    """
    p = GE_APPDATA / "editor_log.txt"
    if not p.is_file():
        return "editor_log.txt not found at " + str(p)
    data = p.read_bytes()
    size = len(data)
    if mode == "errors":
        all_lines = data.decode("utf-8", errors="replace").splitlines()
        sel = [ln for ln in all_lines if re.search(r"error|warning|exception|failed|callstack", ln, re.I)]
        out = sel[-lines:]
        head = str(len(sel)) + " error/warning line(s) in the log; showing last " + str(len(out))
    elif mode == "tail":
        all_lines = data.decode("utf-8", errors="replace").splitlines()
        out = all_lines[-lines:]
        head = "last " + str(len(out)) + " of " + str(len(all_lines)) + " log lines"
    else:
        off = _LOG_STATE["offset"]
        _LOG_STATE["offset"] = size
        if off is None or off > size:  # first read, or the log was truncated/rotated
            all_lines = data.decode("utf-8", errors="replace").splitlines()
            out = all_lines[-lines:]
            head = "(first read) last " + str(len(out)) + " log lines"
        else:
            out = data[off:].decode("utf-8", errors="replace").splitlines()
            head = str(len(out)) + " new log line(s) since last read"
            if len(out) > lines:
                out = out[-lines:]
                head += " (showing last " + str(lines) + ")"
    if not out:
        return head + "."
    return head + ":\n" + "\n".join(out)


def camera_topdown(x: float, z: float, size: float = 200.0, height: float = 400.0,
                   width: int = 1024):
    """Orthographic TOP-DOWN render of an area -- a minimap tile on demand.

    Frames `size` meters (north up) centered on (x, z), renders, then restores
    the camera exactly as it was (position, rotation, FOV, projection). Great
    for checking paint coverage, field shapes, road layouts from above.
    """
    r1 = call_helper("cameraTopSet", {"x": x, "z": z, "size": size, "height": height})
    if r1.startswith("[ERROR]") or "[ERR]" in r1:
        return r1
    try:
        shot = viewport_screenshot("render", int(width), int(width))
    finally:
        call_helper("cameraRestore", {})
    return shot


def camera_orbit(target: str, shots: int = 4, distance: float = 0.0,
                 pitch_deg: float = 35.0, width: int = 800):
    """Orbit a node and return one render per angle -- see something from all
    sides in a single call. shots=4 -> N/E/S/W views. distance<=0 auto-frames.
    The camera stays at the last angle (use camera_look to reframe)."""
    shots = max(2, min(int(shots), 8))
    images = []
    for i in range(shots):
        yaw = i * 360.0 / shots
        r = call_helper("cameraLook", {
            "target": int_or_str(target), "distance": distance,
            "yawDeg": yaw, "pitchDeg": pitch_deg,
        })
        if "[ERR]" in r:
            return r
        shot = viewport_screenshot("render", int(width), int(width * 9 / 16))
        if isinstance(shot, str):
            return shot
        images.append(shot)
    return images


def debug_view(mode: str = "NONE") -> str:
    """Switch the viewport's DEBUG RENDER mode, then screenshot to see it.

    Handy modes: TERRAIN_SLOPES (steepness heatmap), MESH_LOD, TRIANGLE_DENSITY,
    DRAWCALLS, SHADOW_CASTERS, NORMALS, ALBEDO ... 39 total (bad mode lists them).
    Affects the live viewport -- ALWAYS debug_view NONE afterwards."""
    return call_helper("debugView", {"mode": mode})


TOOLS = [viewport_screenshot, camera_look, camera_topdown, camera_orbit,
         debug_view, read_log]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
