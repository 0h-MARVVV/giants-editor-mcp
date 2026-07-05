"""Core bridge tools: health, setup/diagnostics, arbitrary Lua, API knowledge,
shipped scripts, events."""

import os
import re
from pathlib import Path

from .. import config, knowledge
from ..bridge import bridge, GE_APPDATA, ge_version  # GE_APPDATA also hosts scripts/


def setup(game_dir: str = "", install_poller: bool = False) -> str:
    """One-stop setup check: bridge, editor, game dir, helpers, snippets.

    Call with no args to DIAGNOSE the whole chain (the first thing to run when
    anything misbehaves, and the last step of installation). Pass game_dir to
    SET the Farming Simulator 25 install path (needed for $data/... resolution:
    foliage layer discovery, asset catalog) -- it is validated and persisted to
    ge-mcp.config.json. Usually unnecessary: the path auto-detects from the
    editor's own preferences (editor.xml).

    install_poller=true copies lua/ge_mcp_poller.lua into the editor's scripts
    folder so it appears in GE's Scripts menu -- the one manual file-copy of
    the install, automated. (Re)start the editor afterwards and run
    Scripts > GE-MCP Bridge once per session.
    """
    out = []
    if install_poller:
        import shutil
        src = Path(__file__).resolve().parent.parent.parent / "lua" / "ge_mcp_poller.lua"
        dest_dir = GE_APPDATA / "scripts"
        if not src.is_file():
            out.append("[ERR] poller source missing: " + str(src))
        elif not GE_APPDATA.is_dir():
            out.append("[ERR] editor AppData folder not found -- is GIANTS Editor installed?")
        else:
            dest_dir.mkdir(exist_ok=True)
            dest = dest_dir / "ge_mcp_poller.lua"
            already = dest.is_file() and dest.read_bytes() == src.read_bytes()
            if already:
                out.append("poller already installed (identical): " + str(dest))
            else:
                shutil.copy2(src, dest)
                out.append("poller installed: " + str(dest)
                           + "\n(Re)start GIANTS Editor if it is open, then run Scripts > GE-MCP Bridge.")
        out.append("")
    if game_dir:
        p = config.normalize_game_dir(game_dir)
        if not config.looks_like_fs25(p):
            return ("[ERR] '" + str(p) + "' doesn't look like an FS25 install "
                    "(expected a data/ subdir inside). Point at the folder that "
                    "contains FarmingSimulator2025.exe and data/.")
        config.set_value("game_dir", str(p))
        out.append("game dir saved: " + str(p))
        out.append("")

    out.append("ge-mcp setup status")
    r = bridge('return "pong"', timeout=3.0)
    bridge_ok = r["ok"]
    out.append("  bridge:         " + ("OK (editor answering)" if bridge_ok else
               "NOT RESPONDING -- is the editor open with ge_mcp_poller.lua run "
               "from the Scripts menu this session?"))
    out.append("  editor appdata: " + str(GE_APPDATA)
               + ("  (GE " + ge_version() + ")" if GE_APPDATA.is_dir() else "  MISSING"))
    gd, src = config.game_dir()
    if gd is not None:
        out.append("  game dir:       " + str(gd) + "  [" + src + "]")
    else:
        out.append("  game dir:       " + src)
    if bridge_ok:
        rr = bridge("return tostring((__geMcpS and __geMcpS.version) or 'none')", timeout=5.0)
        hv = (rr.get("result") or "?").strip() if rr.get("ok") else "?"
        out.append("  helper library: " + ("not injected yet (auto-injects on first toolkit call)"
                                           if hv == "none" else "v" + hv + " injected"))
    else:
        out.append("  helper library: n/a (editor not running)")
    from .. import snippets as _snip
    n_snips = len(list(_snip.SNIPPETS_DIR.glob("*.json"))) if _snip.SNIPPETS_DIR.is_dir() else 0
    out.append("  snippets:       " + str(n_snips) + " saved")
    out.append("  tool groups:    GE_MCP_GROUPS=" + (os.environ.get("GE_MCP_GROUPS") or "all"))
    if not bridge_ok:
        out.append("")
        out.append("Next: open GIANTS Editor, load your map, run Scripts > GE-MCP Bridge, "
                   "then call setup() again -- expect 'bridge: OK'.")
    return "\n".join(out)


def ping_editor() -> str:
    """Check that the GIANTS Editor bridge is alive and answering (fast: ~5s max)."""
    r = bridge('return "pong from GIANTS Editor"', timeout=5.0)
    if r["ok"]:
        return r["result"]
    return ("Bridge not responding (checked for 5s). Open GIANTS Editor, load your "
            "map, run Scripts > GE-MCP Bridge, then ping again. `setup` shows the "
            "full chain status.")


def run_lua(code: str, force: bool = False) -> str:
    """Execute Lua inside the running GIANTS Editor and return its result.

    Before running, every bare function the snippet calls is checked against what
    is ACTUALLY callable in the editor -- its live _G globals plus the documented
    bindings (and Lua builtins / locals the snippet defines). Unknown names are
    REFUSED with the closest matches instead of executing. When unsure, look a
    function up with search_api / api_signature, or read a shipped helper with
    list_scripts / read_script, first.

    Runs in the editor's global environment via loadstring; end the snippet with
    `return <string>` to get text back (tables come back as "table: 0x.."; build
    a string yourself). print() output goes to the editor log, not the return.

    NOTE: no dry-run safety -- writes (setTranslation, delete, ...) apply
    immediately. Read/preview first if a change is risky. If it works and is
    worth keeping, save_snippet it.

    force=true skips validation (e.g. for a freshly source()'d script whose
    globals aren't in the live snapshot yet -- or call refresh_api to re-snapshot).
    """
    if not force:
        unknown = knowledge.validate_lua(code)
        if unknown:
            lines = ["Refused to run -- these names aren't callable in the editor "
                     "(not in its live globals or the bindings):"]
            for nm in unknown:
                sug = knowledge.suggest(nm)
                if sug:
                    lines.append("  " + nm + "  ->  did you mean: " + ", ".join(sug))
                else:
                    lines.append("  " + nm + "  ->  no close match; try search_api / list_scripts")
            lines.append("Fix the call, or re-call with force=true if it's a real global "
                         "added since the last snapshot (then consider refresh_api).")
            return "[BLOCKED]\n" + "\n".join(lines)
    r = bridge(code)
    return f"[OK]\n{r['result']}" if r["ok"] else f"[ERROR]\n{r['result']}"


def search_api(query: str, limit: int = 25) -> str:
    """Search the editor scripting API by keyword.

    Returns documented functions WITH exact signatures (params:types -> outputs),
    and also lists functions that exist in the live editor but aren't documented
    (callable, no signature -- read a shipped script to learn their usage). This
    is how to do anything without a dedicated tool: find the function, call it via
    run_lua. Examples: search_api("light"), search_api("screenshot"), ("spline").
    """
    if not knowledge.ensure_known() or (not knowledge.api_index() and not knowledge.LIVE_FUNCS):
        return knowledge.load_message()
    q = query.lower().strip()
    name_hits, other_hits = [], []
    for e in knowledge.api_index():
        if q in e["name"].lower():
            name_hits.append(e)
        elif q in e["desc"].lower() or q in e["category"].lower():
            other_hits.append(e)
    hits = name_hits + other_hits

    doc_lower = set(e["name"].lower() for e in knowledge.api_index())
    live_only = sorted(n for n in knowledge.LIVE_FUNCS
                       if q in n.lower() and n.lower() not in doc_lower)

    out = []
    if hits:
        capped = len(hits) > limit
        out.append(str(len(hits)) + " documented match(es) for '" + query + "'"
                   + ((" (showing " + str(limit) + ")") if capped else "") + ":")
        out += [knowledge.api_sig(e) + "   [" + e["category"] + "]" for e in hits[:limit]]
    if live_only:
        out.append("")
        out.append(str(len(live_only)) + " undocumented live function(s) matching '" + query
                   + "' (callable via run_lua; observed signature shown where mined):")
        for n in live_only[:limit]:
            m = knowledge.MINED.get(n)
            if m:
                out.append("  " + m.get("sig", n) + "   [observed: " + str(m.get("calls", "?")) + " calls]")
            else:
                out.append("  " + n)
    if not out:
        return "No functions match '" + query + "'. Try a shorter/different keyword."
    return "\n".join(out)


def api_signature(name: str) -> str:
    """Full signature + parameter docs for one documented API function (exact name)."""
    if not knowledge.ensure_api():
        m = knowledge.MINED.get(name)
        if m:
            return knowledge.format_mined(name, m)
        if name in knowledge.LIVE_FUNCS:
            return name + ": present in the live editor but not documented. Read a shipped " \
                          "script (list_scripts/read_script) to learn its usage."
        return knowledge.load_message()
    e = knowledge.api_by_name(name)
    if e is None:
        m = knowledge.MINED.get(name)
        if m:
            return knowledge.format_mined(name, m)
        if name in knowledge.LIVE_FUNCS:
            return name + ": callable in the editor but not in the documented bindings " \
                          "(no signature available). Find its usage by reading a shipped " \
                          "script via list_scripts / read_script."
        return "No API function named '" + name + "'. Use search_api to find it."
    lines = [knowledge.api_sig(e), "category: " + e["category"], "description: " + e["desc"]]
    if e["inputs"]:
        lines.append("inputs:")
        for n, t, d in e["inputs"]:
            lines.append("  " + n + ": " + t + ("  -- " + d if d else ""))
    else:
        lines.append("inputs: (none)")
    if e["outputs"]:
        lines.append("outputs:")
        for n, t in e["outputs"]:
            lines.append("  " + n + ": " + t)
    else:
        lines.append("outputs: (none)")
    return "\n".join(lines)


def refresh_api() -> str:
    """Reload the documented spec AND re-snapshot the editor's live globals.

    Call this if search says nothing is loaded (server started before the editor),
    after updating the editor, or after source()'ing new scripts so their globals
    show up."""
    knowledge.reset_editor_root()
    knowledge.load_api()
    knowledge.load_live_globals()
    extra = ""
    if knowledge.LIVE_FUNCS:
        extra = "  Live globals snapshot: " + str(len(knowledge.LIVE_FUNCS)) + " functions, " \
                + str(len(knowledge.LIVE_TABLES)) + " tables."
    return knowledge.load_message() + extra + knowledge.mined_message()


def _script_roots():
    """(label, root, subdirs) per script location.

    editor: the install's shipped scripts.  user: the AppData scripts folder --
    where community panel scripts live (spline paint/height panels, Field
    Toolkit, ...), the richest source of proven engine-API usage.
    """
    roots = []
    inst = knowledge.editor_root()
    if inst is not None:
        roots.append(("editor", inst, ("scripts", "shared", "tools")))
    user = GE_APPDATA / "scripts"
    if user.is_dir():
        roots.append(("user", user, ("",)))
    return roots


def list_scripts(query: str = "", limit: int = 100) -> str:
    """List Lua scripts from BOTH the editor install and the user scripts folder.

    editor: paths under the install (scripts/, shared/, tools/) -- the shipped
    helpers. user: %LOCALAPPDATA%/GIANTS Editor .../scripts -- the community
    panel scripts the modder actually uses; reading them is the best way to
    learn proven engine-API patterns. Shows each file's header Name/Description
    when present. Optional query filters by path/name/description. Use
    read_script with the exact prefixed path shown here.
    """
    roots = _script_roots()
    if not roots:
        return "No script locations available (is GIANTS Editor running with the poller?)."
    q = query.lower().strip()
    rows = []
    for label, root, subs in roots:
        for sub in subs:
            base = (root / sub) if sub else root
            if not base.is_dir():
                continue
            for p in sorted(base.rglob("*.lua")):
                rel = label + ":" + p.relative_to(root).as_posix()
                name = desc = ""
                try:
                    head = p.read_text(encoding="utf-8", errors="replace")[:2000]
                    m = re.search(r'--\s*Name:[ \t]*(.+)', head)
                    name = m.group(1).strip() if m else ""
                    m = re.search(r'--\s*Description:[ \t]*(.+)', head)
                    desc = m.group(1).strip() if m else ""
                except Exception:
                    pass
                if q and q not in (rel + " " + name + " " + desc).lower():
                    continue
                label_row = rel + (("   -- " + name) if name else "") + ((" : " + desc) if desc else "")
                rows.append(label_row)
    if not rows:
        return ("No scripts match '" + query + "'.") if q else "No .lua scripts found."
    capped = len(rows) > limit
    header = str(len(rows)) + " script(s)" + ((" matching '" + query + "'") if q else "")
    if capped:
        header += " (showing " + str(limit) + "; refine the query)"
    return header + ":\n" + "\n".join("  " + r for r in rows[:limit])


def read_script(path: str, max_chars: int = 20000) -> str:
    """Read one Lua script (shipped or user) to learn its functions and usage.

    `path` as shown by list_scripts: 'editor:scripts/camera/savebillboard.lua'
    or 'user:Spline_Paint_Panel_25_UPDATED.lua'. An unprefixed path is tried
    against the editor install first, then the user scripts folder. Read-only,
    contained to those two directories. After learning the API, call the
    functions via run_lua (or productize with save_snippet).
    """
    roots = {label: root for label, root, _ in _script_roots()}
    if not roots:
        return "No script locations available (is GIANTS Editor running with the poller?)."
    wanted = path.strip()
    low = wanted.lower()
    if low.startswith("editor:") or low.startswith("user:"):
        label, rel = wanted.split(":", 1)
        label = label.lower()
        candidates = [(label, roots[label])] if label in roots else []
        if not candidates:
            return "Script location '" + label + ":' not available right now."
    else:
        rel = wanted
        candidates = [(lbl, roots[lbl]) for lbl in ("editor", "user") if lbl in roots]
    for label, root in candidates:
        root_r = root.resolve()
        target = (root / rel).resolve()
        try:
            target.relative_to(root_r)
        except ValueError:
            return "Refused: path escapes the " + label + " scripts directory."
        if target.suffix.lower() == ".lua" and target.is_file():
            text = target.read_text(encoding="utf-8", errors="replace")
            truncated = len(text) > max_chars
            note = ("\n\n... (truncated at " + str(max_chars) + " chars; raise max_chars)") if truncated else ""
            return ("FILE: " + label + ":" + target.relative_to(root_r).as_posix()
                    + "\n\n" + text[:max_chars] + note)
    return "Not a .lua file in the editor install or user scripts: " + path


def get_events(limit: int = 50, since: int = 0, clear: bool = False) -> str:
    """Recent editor events captured by the in-editor poller, oldest -> newest.

    The poller registers listeners on the editor's hook system (scripts/Hooks.lua)
    and keeps a ring buffer of what happens in the editor:
      SELECTION (node selected/deselected), SAVE, NODE_CLONED, NODE_DELETED,
      FILE_OPEN, FILE_IMPORTED.
    Use this to OBSERVE what the user is doing in the editor and react, instead of
    only acting when asked. Each event has a monotonic seq; poll incrementally with
    `since` (return only seq > since). Requires the updated poller to be loaded.
    NOTE: script-initiated delete() does not fire NODE_DELETED (UI deletes do).

    limit  - max events returned (keeps the most recent if there are more).
    since  - only return events whose seq > this value (incremental polling).
    clear  - clear the buffer after reading.
    """
    clear_lua = "__geMcpEvents = {} " if clear else ""
    snippet = (
        "local b = __geMcpEvents or {} "
        "local since = " + str(int(since)) + " local lim = " + str(int(limit)) + " "
        "local out = {} "
        "for i=1,#b do local e=b[i] "
        "if e.seq > since then out[#out+1]=e.seq..'\\t'..(e.t or '')..'\\t'..tostring(e.kind)..'\\t'..tostring(e.detail or '') end end "
        "while #out > lim do table.remove(out,1) end "
        "local armed = __geMcpEventsArmed and 'armed' or 'NOTarmed' "
        "local seq = __geMcpSeq or 0 "
        + clear_lua +
        "return 'EVTS\\t'..tostring(seq)..'\\t'..armed..'\\t'..tostring(#out)..'\\n'..table.concat(out,'\\n')"
    )
    r = bridge(snippet)
    if not r["ok"]:
        return "Could not read events (is the poller loaded?).\n" + r["result"]
    raw = r["result"] or ""
    head, _nl, body = raw.partition("\n")
    parts = head.split("\t")
    if len(parts) < 4 or parts[0] != "EVTS":
        return "Unexpected event payload:\n" + raw
    latest_seq, armed = parts[1], parts[2]
    if armed != "armed":
        return ("Event capture is NOT armed in the poller -- reload ge_mcp_poller.lua "
                "from the editor's Scripts menu (latest seq=" + latest_seq + ").")
    rows = [ln for ln in body.split("\n") if ln]
    if not rows:
        scope = (" since seq " + str(since)) if since else ""
        return "No editor events" + scope + ". (armed; latest seq=" + latest_seq + ")"
    out = ["Editor events (latest seq=" + latest_seq + ", showing " + str(len(rows)) + "):"]
    for ln in rows:
        f = ln.split("\t")
        out.append(("  [" + f[0] + "] " + f[1] + "  " + f[2] + ": " + f[3]) if len(f) >= 4 else "  " + ln)
    return "\n".join(out)


TOOLS = [setup, ping_editor, run_lua, search_api, api_signature, refresh_api,
         list_scripts, read_script, get_events]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
