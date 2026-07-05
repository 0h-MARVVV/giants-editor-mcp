"""Scene-level operations: saving, on-disk backups (and, in future sessions, audits)."""

import re
import shutil
import subprocess
import time
from pathlib import Path

from .. import config
from ..bridge import bridge


def backup_scene(note: str = "", include_data: bool = True) -> str:
    """Timestamped on-disk backup of the open map -- the crash insurance.

    Copies map.i3d, its sibling cache files, and (by default) the maps data/
    folder (DEM, density/weight maps -- everything terrain and foliage paints
    touch) to map_backups/<mod>-<timestamp>[-note]/ next to this package
    (override location with a "backup_dir" key in ge-mcp.config.json).

    Backs up the files as LAST SAVED: run save_scene first to snapshot current
    edits -- the report shows how stale the last save is. Restore = close the
    map in GE, copy the backed-up files over the originals, reopen.
    """
    r = bridge("return getSceneFilename()", timeout=6.0)
    if not r["ok"] or not (r["result"] or "").strip():
        return "[ERROR] could not get the scene filename from the editor.\n" + r["result"]
    scene = Path(r["result"].strip())
    if not scene.is_file():
        return "[ERROR] scene file not found on disk: " + str(scene)

    stale_s = time.time() - scene.stat().st_mtime
    stale = ("%dm%02ds ago" % (stale_s // 60, stale_s % 60)) if stale_s < 3600 \
        else ("%.1fh ago" % (stale_s / 3600))

    files = sorted(scene.parent.glob(scene.name + "*"))       # map.i3d + .cache siblings
    data_dir = scene.parent / "data"
    total = sum(f.stat().st_size for f in files if f.is_file())
    if include_data and data_dir.is_dir():
        total += sum(f.stat().st_size for f in data_dir.rglob("*") if f.is_file())

    root = Path(config.load().get("backup_dir") or (config.CONFIG_PATH.parent / "map_backups"))
    free = shutil.disk_usage(root.parent if not root.exists() else root).free
    if free < total * 1.2:
        return "[ERROR] not enough free space at " + str(root) + \
               " (%.0f MB needed, %.0f MB free)" % (total / 1e6, free / 1e6)

    tag = re.sub(r"[^a-zA-Z0-9_-]+", "-", note.strip())[:40].strip("-")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    mod = scene.parent.parent.name or scene.stem
    dest = root / (mod + "-" + stamp + (("-" + tag) if tag else ""))
    dest.mkdir(parents=True, exist_ok=False)

    n = 0
    for f in files:
        if f.is_file():
            shutil.copy2(f, dest / f.name)
            n += 1
    if include_data and data_dir.is_dir():
        shutil.copytree(data_dir, dest / "data")
        n += sum(1 for f in data_dir.rglob("*") if f.is_file())

    return ("BACKED UP " + str(n) + " file(s), %.0f MB -> " % (total / 1e6) + str(dest)
            + "\nsnapshot of the last save (" + stale + ")"
            + (" -- run save_scene first if you meant to include unsaved edits" if stale_s > 120 else "")
            + "\nrestore: close the map in GE, copy these files back over "
            + str(scene.parent) + ", reopen.")


def save_scene(timeout_s: int = 45) -> str:
    """Save the scene: focuses the GIANTS Editor window, sends Ctrl+S, then waits
    for the editor's ON_SAVE event to confirm the save actually happened.

    There is NO scriptable save binding, so this briefly steals window focus.
    If no SAVE event arrives (e.g. a modal dialog was open), it says so --
    verify manually in that case. Use after any committed paint/terrain work
    (crash = unsaved work lost)."""
    r = bridge("return tostring(__geMcpSeq or 0)", timeout=6.0)
    if not r["ok"]:
        return "Bridge not answering; cannot verify a save. " + r["result"]
    try:
        seq0 = int((r["result"] or "0").strip())
    except ValueError:
        seq0 = 0
    ps = ("$ws = New-Object -ComObject WScript.Shell; "
          "if (-not $ws.AppActivate('GIANTS Editor')) { Write-Output 'NOACTIVATE'; exit 1 }; "
          "Start-Sleep -Milliseconds 400; $ws.SendKeys('^s'); Write-Output 'SENT'")
    try:
        proc = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                              capture_output=True, text=True, timeout=15)
    except Exception as exc:
        return "[ERROR] could not send Ctrl+S: " + str(exc)
    if "NOACTIVATE" in (proc.stdout or ""):
        return "[ERROR] could not focus a 'GIANTS Editor' window (is it running?)"
    poll = ("local b = __geMcpEvents or {} "
            "for i = #b, 1, -1 do local e = b[i] "
            "if e.seq > " + str(seq0) + " and e.kind == 'SAVE' then "
            "return e.seq .. '\\t' .. tostring(e.detail or '') end end return ''")
    deadline = time.time() + max(5, timeout_s)
    while time.time() < deadline:
        time.sleep(0.6)
        r2 = bridge(poll, timeout=8.0)
        if r2["ok"] and (r2["result"] or "").strip():
            detail = r2["result"].split("\t", 1)
            return "SAVED (ON_SAVE event confirmed): " + (detail[1] if len(detail) > 1 else "")
    return ("Ctrl+S was sent but NO SAVE event arrived within " + str(timeout_s) + "s. "
            "A dialog may have been open or the save is still running -- check the editor.")


TOOLS = [save_scene, backup_scene]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
