"""Transport: XML mailbox files in the editor's AppData folder.

The in-editor poller (lua/ge_mcp_poller.lua) watches mcp_request.xml on the
editor's update loop, executes the Lua via loadstring, and writes
mcp_response.xml. Payloads are base64 both ways (the editor's XML layer turns
newlines into spaces). One request in flight at a time keeps it race-free.
"""

import os
import re
import time
import uuid
import base64
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_TIMEOUT = 120.0
POLL_INTERVAL = 0.05


def _resolve_ge_appdata() -> Path:
    """The editor's AppData folder, where the mailbox lives.

    In-editor the poller uses getAppDataPath() == %LOCALAPPDATA%\\<version dir>,
    so the folder name changes with every editor update. Resolve dynamically
    (hardcoding broke on the 10.0.12 -> 10.0.13 update). Overrides:
      GE_APPDATA     - full path, used as-is
      GE_VERSION_DIR - just the folder name under %LOCALAPPDATA%
    otherwise pick the highest-versioned "GIANTS Editor 64bit X.Y.Z" present.
    """
    env_dir = os.environ.get("GE_APPDATA")
    if env_dir and Path(env_dir).is_dir():
        return Path(env_dir)
    local = Path(os.environ["LOCALAPPDATA"])
    env_ver = os.environ.get("GE_VERSION_DIR")
    if env_ver:
        return local / env_ver
    best, best_key = None, None
    for p in local.glob("GIANTS Editor 64bit *"):
        if not p.is_dir():
            continue
        m = re.search(r"(\d+)\.(\d+)\.(\d+)\s*$", p.name)
        key = tuple(int(x) for x in m.groups()) if m else (0, 0, 0)
        if best_key is None or key > best_key:
            best, best_key = p, key
    return best if best is not None else (local / "GIANTS Editor 64bit 10.0.13")


GE_APPDATA = _resolve_ge_appdata()

REQ_PATH = GE_APPDATA / "mcp_request.xml"
RESP_PATH = GE_APPDATA / "mcp_response.xml"
TMP_PATH = GE_APPDATA / "mcp_request.tmp"


def ge_version() -> str:
    """Editor version string derived from the AppData folder name."""
    m = re.search(r"(\d+\.\d+\.\d+)\s*$", GE_APPDATA.name)
    return m.group(1) if m else GE_APPDATA.name


def bridge(code: str, timeout: float = DEFAULT_TIMEOUT) -> dict:
    """Send Lua to the editor and wait for the result. Returns {ok, result}."""
    if not GE_APPDATA.is_dir():
        return {"ok": False,
                "result": f"GIANTS Editor AppData folder not found:\n  {GE_APPDATA}\n"
                          f"If your editor version differs, set GE_VERSION_DIR."}

    req_id = uuid.uuid4().hex
    code_b64 = base64.b64encode(code.encode("utf-8")).decode("ascii")

    try:
        RESP_PATH.unlink()
    except FileNotFoundError:
        pass

    body = ('<?xml version="1.0" encoding="utf-8" standalone="no"?>\n'
            "<mcp>\n"
            f"<id>{req_id}</id>\n"
            f"<code>{code_b64}</code>\n"
            "</mcp>\n")
    TMP_PATH.write_text(body, encoding="utf-8")
    os.replace(TMP_PATH, REQ_PATH)

    deadline = time.time() + timeout
    while time.time() < deadline:
        if RESP_PATH.exists():
            try:
                root = ET.fromstring(RESP_PATH.read_bytes())
            except (ET.ParseError, OSError):
                time.sleep(POLL_INTERVAL)
                continue
            if (root.findtext("id") or "") != req_id:
                time.sleep(POLL_INTERVAL)
                continue
            ok = (root.findtext("ok") or "false").strip() == "true"
            result_b64 = (root.findtext("result") or "").strip()
            result = (base64.b64decode(result_b64).decode("utf-8", errors="replace")
                      if result_b64 else "")
            try:
                RESP_PATH.unlink()
            except FileNotFoundError:
                pass
            return {"ok": ok, "result": result}
        time.sleep(POLL_INTERVAL)

    return {"ok": False,
            "result": f"No response within {timeout:.0f}s. Is ge_mcp_poller.lua "
                      f"loaded and running (loop playing) in GIANTS Editor?"}
