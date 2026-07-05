"""What is callable in the editor, in layers:

* scriptBinding.xml / ScriptBindingBuiltins.xml -> documented functions with
  signatures (read live from the install via getEditorDirectory()).
* the editor's live _G table -> the TRUE set of callable globals (a superset:
  undocumented engine functions plus whatever shipped scripts defined).
* mined_signatures.json -> observed signatures for undocumented-but-live
  functions, mined from FS25/editor Lua corpora call-sites.

Also home of the run_lua validator (it needs these name sets).
"""

import difflib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

from . import validation
from .bridge import bridge

_API_INDEX = []
_API_BY_NAME = {}        # lowercased name -> entry
API_NAMES = set()        # exact-case documented names
LIVE_FUNCS = set()       # exact-case function names actually present in _G
LIVE_TABLES = set()      # exact-case table names present in _G
_EDITOR_ROOT = None      # cached editor install Path
_API_LOAD_MSG = ""
MINED = {}               # name -> {sig, source, calls, arity, examples}
_MINED_MSG = ""
# known_functions.json: observed signatures for undocumented-but-live engine
# functions. Prefer the local full version (with call-site examples) when it
# exists — it is gitignored and never shipped. Falls back to the facts-only
# file that ships in the zip.
_MINED_DIR = Path(__file__).resolve().parent.parent
MINED_PATH = (_MINED_DIR / "known_functions.full.json"
              if (_MINED_DIR / "known_functions.full.json").is_file()
              else _MINED_DIR / "known_functions.json")


def editor_root():
    """Locate (and cache) the editor install directory."""
    global _EDITOR_ROOT
    if _EDITOR_ROOT is not None:
        return _EDITOR_ROOT
    import os
    env = os.environ.get("GE_BINDING_DIR") or os.environ.get("GE_EDITOR_DIR")
    if env and Path(env).is_dir():
        _EDITOR_ROOT = Path(env)
        return _EDITOR_ROOT
    try:
        r = bridge('return getEditorDirectory()', timeout=4.0)
        if r.get("ok"):
            d = (r.get("result") or "").strip()
            if d and Path(d).is_dir():
                _EDITOR_ROOT = Path(d)
                return _EDITOR_ROOT
    except Exception:
        pass
    return None


def reset_editor_root():
    global _EDITOR_ROOT
    _EDITOR_ROOT = None


def _api_xml_dir():
    """Dir holding scriptBinding.xml: editor install, else next to the package."""
    root = editor_root()
    if root is not None and (root / "scriptBinding.xml").is_file():
        return root
    here = MINED_PATH.parent
    if (here / "scriptBinding.xml").is_file():
        return here
    return None


def _load_mined():
    global MINED, _MINED_MSG
    MINED = {}
    _MINED_MSG = ""
    if not MINED_PATH.is_file():
        return
    try:
        data = json.loads(MINED_PATH.read_text(encoding="utf-8"))
        MINED = data.get("signatures", {}) or {}
        _MINED_MSG = "  Known functions: " + str(len(MINED)) + " with observed signatures (undocumented-but-live)."
    except Exception as exc:
        _MINED_MSG = "  Known functions failed to load: " + str(exc)


def format_mined(name, m):
    """Render a mined-signature entry for api_signature."""
    src = ("official FS25 game binding" if m.get("source") == "game-binding"
           else "OBSERVED from FS25/editor corpus call-sites -- param names inferred, NOT official")
    lines = [m.get("sig", name + "(...)"),
             "source: " + src,
             "observed: " + str(m.get("calls", "?")) + " call-site(s), arity " + str(m.get("arity", "?"))]
    if m.get("examples"):
        lines.append("examples:")
        lines += ["  " + ex for ex in m["examples"]]
    return "\n".join(lines)


def load_api():
    """Load documented bindings (signatures) from the XML spec."""
    global _API_INDEX, _API_BY_NAME, API_NAMES, _API_LOAD_MSG
    _load_mined()
    _API_INDEX = []
    _API_BY_NAME = {}
    API_NAMES = set()
    base = _api_xml_dir()
    if base is None:
        _API_LOAD_MSG = ("API spec not loaded yet. It is read from the editor install via "
                         "getEditorDirectory(); make sure GIANTS Editor is running with the "
                         "poller loaded, then call refresh_api.")
        return
    total, loaded = 0, []
    for fname in ("scriptBinding.xml", "ScriptBindingBuiltins.xml"):
        p = base / fname
        if not p.is_file():
            continue
        try:
            root = ET.parse(p).getroot()
        except Exception as exc:
            _API_LOAD_MSG += "Failed to parse " + fname + ": " + str(exc) + " "
            continue
        for fn in root.findall("function"):
            nm = fn.get("name") or ""
            ie, oe = fn.find("input"), fn.find("output")
            entry = {
                "name": nm,
                "category": fn.get("category") or "",
                "desc": fn.get("desc") or "",
                "inputs": [(p2.get("name") or "", p2.get("type") or "", p2.get("desc") or "")
                           for p2 in (ie.findall("param") if ie is not None else [])],
                "outputs": [(p2.get("name") or "", p2.get("type") or "")
                            for p2 in (oe.findall("param") if oe is not None else [])],
            }
            _API_INDEX.append(entry)
            _API_BY_NAME[nm.lower()] = entry
            API_NAMES.add(nm)
            total += 1
        loaded.append(fname)
    _API_LOAD_MSG = "Loaded " + str(total) + " documented functions from " + str(base) + " (" + ", ".join(loaded) + ")."


def load_live_globals():
    """Ask the running editor for every global function/table actually present."""
    global LIVE_FUNCS, LIVE_TABLES
    snippet = (
        'local f,t={},{} '
        'for k,v in pairs(_G) do '
        '  if type(k)=="string" then '
        '    if type(v)=="function" then f[#f+1]=k '
        '    elseif type(v)=="table" then t[#t+1]=k end '
        '  end '
        'end '
        'return table.concat(f,",").."|||"..table.concat(t,",")'
    )
    try:
        r = bridge(snippet, timeout=6.0)
    except Exception:
        return
    if not r.get("ok"):
        return
    res = r.get("result") or ""
    if "|||" not in res:
        return
    fpart, tpart = res.split("|||", 1)
    LIVE_FUNCS = set(x for x in fpart.split(",") if x)
    LIVE_TABLES = set(x for x in tpart.split(",") if x)


def ensure_api():
    if not _API_INDEX:
        load_api()
    return bool(_API_INDEX)


def ensure_known():
    """Make sure we have something to validate against (docs and/or live globals)."""
    if not _API_INDEX:
        load_api()
    if not LIVE_FUNCS:
        load_live_globals()
    return bool(API_NAMES or LIVE_FUNCS)


def api_sig(e):
    istr = ", ".join(n + ":" + t for n, t, _ in e["inputs"])
    ostr = ", ".join(n + ":" + t for n, t in e["outputs"]) or "-"
    return e["name"] + "(" + istr + ") -> " + ostr


def api_index():
    return _API_INDEX


def api_by_name(name):
    return _API_BY_NAME.get(name.lower().strip())


def load_message():
    return _API_LOAD_MSG


def mined_message():
    return _MINED_MSG


# ---- validation entry points -------------------------------------------------
def validate_lua(code: str):
    """Names called that are not known to exist. None = couldn't validate (allow)."""
    if not ensure_known():
        return None
    stripped = validation.strip_lua(code)
    defined = validation.defined_names(stripped)
    unknown, seen = [], set()
    for nm in validation.called_globals(stripped):
        if nm in seen:
            continue
        seen.add(nm)
        if (nm in validation.LUA_KEYWORDS or nm in validation.LUA_BUILTINS
                or nm in validation.EDITOR_GLOBALS or nm in defined
                or nm in API_NAMES or nm in LIVE_FUNCS):
            continue
        unknown.append(nm)
    return unknown


def suggest(nm: str):
    pool = list(API_NAMES | LIVE_FUNCS)
    return difflib.get_close_matches(nm, pool, n=5, cutoff=0.5)
