"""Injected Lua helper library machinery.

The heavy Lua lives in lua/ge_mcp_helpers.lua. It is sent to the editor once
per editor session (loadstring into _G as __geMcpS); every toolkit call is then
a one-line invocation. If the editor restarts, the [NOHELPERS] sentinel
triggers automatic re-injection. Bump HELPERS_VERSION here AND the `version`
field at the top of the Lua file together.
"""

import re
from pathlib import Path

from .bridge import bridge, DEFAULT_TIMEOUT

HELPERS_VERSION = 12
HELPERS_PATH = Path(__file__).resolve().parent.parent / "lua" / "ge_mcp_helpers.lua"


def lua_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    s = str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return '"' + s + '"'


def lua_args(d):
    parts = [k + "=" + lua_val(v) for k, v in d.items() if v is not None]
    return "{" + ", ".join(parts) + "}"


def int_or_str(v):
    """Node/layer specs arrive as strings; pass numerics through as numbers."""
    s = str(v).strip()
    return int(s) if re.fullmatch(r"-?\d+", s) else s


def inject_helpers():
    if not HELPERS_PATH.is_file():
        return "helper library missing: " + str(HELPERS_PATH)
    code = HELPERS_PATH.read_text(encoding="utf-8")
    r = bridge(code, timeout=30.0)
    if not r["ok"]:
        return "helper injection failed:\n" + r["result"]
    return None


_EDITOR_SEEN = False     # set once a bridge call succeeds; re-armed on timeout


def call_helper(fn, args, timeout=DEFAULT_TIMEOUT):
    global _EDITOR_SEEN
    if not _EDITOR_SEEN:
        # Fast liveness gate: a live editor echoes in <1s, so a short probe
        # spares every toolkit tool the full timeout when the editor isn't
        # running (the fresh-install case: server registered, GE not started).
        # Costs one extra round trip only until the first success.
        probe = bridge("return (__geMcpS and __geMcpS.version or 0) .. ''", timeout=8.0)
        if not probe["ok"]:
            return ("[ERROR]\nEditor not answering (8s probe). Open GIANTS Editor, "
                    "load your map, run Scripts > GE-MCP Bridge, then retry. `setup` "
                    "shows the full chain. (If the editor is busy loading a big map, "
                    "just retry.)")
        _EDITOR_SEEN = True
    snippet = ("if __geMcpS == nil or (__geMcpS.version or 0) < " + str(HELPERS_VERSION)
               + " then return '[NOHELPERS]' end "
               + "return __geMcpS." + fn + "(" + lua_args(args) + ")")
    r = bridge(snippet, timeout=timeout)
    if r["ok"] and (r["result"] or "").strip() == "[NOHELPERS]":
        err = inject_helpers()
        if err:
            return "[ERROR]\n" + err
        r = bridge(snippet, timeout=timeout)
    if not r["ok"] and "No response within" in (r["result"] or ""):
        _EDITOR_SEEN = False        # editor went away: next call probes again
    return ("[OK]\n" if r["ok"] else "[ERROR]\n") + r["result"]
