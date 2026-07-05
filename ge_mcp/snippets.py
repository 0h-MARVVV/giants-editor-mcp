"""Saved-script library: scripts that proved themselves, replayable by name.

Each snippet is one JSON file in snippets/ (next to the package):
  {name, description, lua, params: [{name, default}], created, ge_version,
   runs, failures, last_ok, last_run}

Parameters reach the Lua as a global-free `ARGS` table prepended to the code
(`local ARGS = {width=3, layer="decoBush"} <lua>`), using the same marshalling
as the helper library. Snippets bypass the run_lua validator: they were
validated when saved, and the library records failures so drift is visible.

Zero marginal schema cost: three MCP tools cover unlimited snippets, and
snippets/ is plain files, so modders can share snippet packs.
"""

import json
import re
import time
from pathlib import Path

from .bridge import bridge, ge_version, DEFAULT_TIMEOUT
from .helpers import lua_val

SNIPPETS_DIR = Path(__file__).resolve().parent.parent / "snippets"

_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,63}$")


def _path(name: str) -> Path:
    return SNIPPETS_DIR / (name + ".json")


def _load(name: str):
    p = _path(name)
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def _store(data: dict):
    SNIPPETS_DIR.mkdir(parents=True, exist_ok=True)
    _path(data["name"]).write_text(
        json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def parse_params_spec(spec: str):
    """'width=3.0, layer=decoBush, count' -> [{'name':..., 'default':...}, ...]

    Defaults are typed: numeric -> number, true/false -> bool, else string.
    A bare name means required (no default).
    """
    out = []
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            nm, dv = part.split("=", 1)
            out.append({"name": nm.strip(), "default": _typed(dv.strip())})
        else:
            out.append({"name": part})
    return out


def _typed(s: str):
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    if re.fullmatch(r"-?\d*\.\d+([eE][+-]?\d+)?", s):
        return float(s)
    if s.lower() in ("true", "false"):
        return s.lower() == "true"
    return s


def parse_args(args: str):
    """Accept JSON ('{"width": 5}') or 'width=5, layer=decoBush' k=v pairs."""
    args = (args or "").strip()
    if not args:
        return {}
    if args.startswith("{"):
        try:
            d = json.loads(args)
            if isinstance(d, dict):
                return d
        except Exception:
            pass
    out = {}
    for part in args.split(","):
        part = part.strip()
        if not part:
            continue
        if "=" not in part:
            return None  # malformed
        nm, dv = part.split("=", 1)
        out[nm.strip()] = _typed(dv.strip())
    return out


def build_args_table(spec_params, given: dict):
    """Merge defaults + given args into a Lua ARGS table literal.

    Returns (lua_literal, missing_required_names).
    """
    vals = {}
    missing = []
    for p in spec_params or []:
        nm = p["name"]
        if nm in given:
            vals[nm] = given[nm]
        elif "default" in p:
            vals[nm] = p["default"]
        else:
            missing.append(nm)
    # allow extra args not in the spec (forward-compat)
    for k, v in given.items():
        vals.setdefault(k, v)
    body = ", ".join(k + "=" + lua_val(v) for k, v in vals.items())
    return "{" + body + "}", missing


def save(name, lua, description="", params="", overwrite=False):
    name = (name or "").strip().lower()
    if not _NAME_RE.match(name):
        return "[ERR] name must be 2-64 chars of a-z 0-9 _ - (got '" + name + "')"
    if not (lua or "").strip():
        return "[ERR] empty lua"
    if _load(name) is not None and not overwrite:
        return ("[ERR] snippet '" + name + "' exists. Pass overwrite=true to replace it "
                "(its run history will reset).")
    data = {
        "name": name,
        "description": description or "",
        "lua": lua,
        "params": parse_params_spec(params),
        "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        "ge_version": ge_version(),
        "runs": 0,
        "failures": 0,
        "last_ok": None,
        "last_run": None,
    }
    _store(data)
    pnames = ", ".join(p["name"] + ("=" + str(p["default"]) if "default" in p else "")
                       for p in data["params"]) or "(none)"
    return ("saved snippet '" + name + "'  params: " + pnames +
            "  (GE " + data["ge_version"] + ")")


def run(name, args="", timeout=DEFAULT_TIMEOUT):
    data = _load((name or "").strip().lower())
    if data is None:
        return "[ERR] no snippet named '" + str(name) + "'. See list_snippets."
    given = parse_args(args)
    if given is None:
        return "[ERR] could not parse args -- use 'k=v, k2=v2' or a JSON object"
    table, missing = build_args_table(data.get("params"), given)
    if missing:
        return "[ERR] missing required arg(s): " + ", ".join(missing)
    code = "local ARGS = " + table + "\n" + data["lua"]
    r = bridge(code, timeout=timeout)
    data["runs"] = data.get("runs", 0) + 1
    if not r["ok"]:
        data["failures"] = data.get("failures", 0) + 1
    data["last_ok"] = bool(r["ok"])
    data["last_run"] = time.strftime("%Y-%m-%d %H:%M:%S")
    _store(data)
    return ("[OK]\n" if r["ok"] else "[ERROR]\n") + r["result"]


def listing(query=""):
    SNIPPETS_DIR.mkdir(parents=True, exist_ok=True)
    q = (query or "").strip().lower()
    rows = []
    for p in sorted(SNIPPETS_DIR.glob("*.json")):
        data = _load(p.stem)
        if data is None:
            continue
        hay = (data["name"] + " " + data.get("description", "")).lower()
        if q and q not in hay:
            continue
        pnames = ", ".join(pp["name"] + ("=" + str(pp["default"]) if "default" in pp else "")
                           for pp in data.get("params", []))
        flag = ""
        if data.get("runs"):
            flag = "  [runs " + str(data["runs"])
            if data.get("failures"):
                flag += ", failures " + str(data["failures"])
            if data.get("last_ok") is False:
                flag += ", LAST RUN FAILED"
            flag += "]"
        rows.append("  " + data["name"] + ("(" + pnames + ")" if pnames else "()")
                    + " -- " + (data.get("description") or "(no description)") + flag)
    if not rows:
        return ("No snippets match '" + query + "'.") if q else \
            "No snippets saved yet. When a run_lua works and is worth keeping, save_snippet it."
    return str(len(rows)) + " snippet(s):\n" + "\n".join(rows)
