"""Offline test suite -- no editor, no MCP session, no dependencies.

Run from the repo root:  python tests/offline/run_all.py
Exit code 0 = all passed.
"""

import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"  {status}  {name}" + (f"  ({detail})" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


# ---- validator ---------------------------------------------------------------
def test_validator():
    print("validator (scanner + unknown-call detection):")
    import ge_mcp.knowledge as K
    K.API_NAMES = set()
    K.LIVE_FUNCS = {"print"}          # minimal fake live set; skips bridge
    cases = [
        ('print("call func (x) inside a string")', []),
        ('local s = "has -- dashes" bogusFn(s)', ["bogusFn"]),
        ('--[[ blockFn( ]] print("k")', []),
        ('local t = [[long bracket fnCall( here]] print(t)', []),
        ('local q = "esc \\" quote fn( x" print(q)', []),
        ('local a = [=[ level ]] fn( ]=] print(a)', []),
        ('realUnknownFn(1)', ["realUnknownFn"]),
        ('local x = 5 -- trailing comment\nprint(x)', []),
    ]
    for code, expect in cases:
        got = K.validate_lua(code) or []
        check(repr(code[:44]), got == expect, f"got {got}, want {expect}")
    K.LIVE_FUNCS = set()


# ---- lua marshalling -----------------------------------------------------------
def test_marshalling():
    print("lua marshalling:")
    from ge_mcp.helpers import lua_val, lua_args, int_or_str
    check("bool true", lua_val(True) == "true")
    check("bool False before int", lua_val(False) == "false")
    check("int", lua_val(3) == "3")
    check("float", lua_val(0.5) == "0.5")
    check("string escape", lua_val('a"b\\c\nd') == '"a\\"b\\\\c\\nd"')
    check("args skip None", lua_args({"a": 1, "b": None, "c": "x"}) == '{a=1, c="x"}')
    check("int_or_str numeric", int_or_str(" 42 ") == 42)
    check("int_or_str name", int_or_str("field001") == "field001")
    check("int_or_str negative", int_or_str("-7") == -7)


# ---- appdata resolver -----------------------------------------------------------
def test_appdata():
    print("appdata resolver:")
    from ge_mcp.bridge import _resolve_ge_appdata
    with tempfile.TemporaryDirectory() as td:
        old = os.environ.get("GE_APPDATA")
        os.environ["GE_APPDATA"] = td
        try:
            check("GE_APPDATA override wins", str(_resolve_ge_appdata()) == td)
        finally:
            if old is None:
                del os.environ["GE_APPDATA"]
            else:
                os.environ["GE_APPDATA"] = old


# ---- snippets -------------------------------------------------------------------
def test_snippets():
    print("snippet library (file roundtrip, no editor):")
    import ge_mcp.snippets as S
    with tempfile.TemporaryDirectory() as td:
        old_dir = S.SNIPPETS_DIR
        S.SNIPPETS_DIR = Path(td)
        try:
            r = S.save("test-one", "return tostring(ARGS.a + ARGS.b)",
                       "adds two numbers", "a=1, b=2.5")
            check("save ok", r.startswith("saved snippet"), r)
            check("bad name refused", S.save("Bad Name!", "return 1").startswith("[ERR]"))
            check("dup refused", S.save("test-one", "return 2").startswith("[ERR]"))
            check("overwrite allowed", S.save("test-one", "return tostring(ARGS.a)",
                                              params="a", overwrite=True).startswith("saved"))
            lst = S.listing()
            check("listing shows it", "test-one" in lst and "1 snippet(s)" in lst, lst)
            check("listing query filter", "No snippets match" in S.listing("zzz"))
            # arg building
            table, missing = S.build_args_table([{"name": "a"}, {"name": "b", "default": 2}], {"a": 5})
            check("args merge defaults", table == "{a=5, b=2}", table)
            check("no missing", missing == [])
            _, missing2 = S.build_args_table([{"name": "a"}], {})
            check("missing required detected", missing2 == ["a"])
            check("parse k=v", S.parse_args("x=1, s=hi, f=true") == {"x": 1, "s": "hi", "f": True})
            check("parse json", S.parse_args('{"x": 1.5}') == {"x": 1.5})
            check("parse malformed", S.parse_args("nonsense") is None)
        finally:
            S.SNIPPETS_DIR = old_dir


# ---- foliage xml parsing ---------------------------------------------------------
def test_foliage_parse():
    print("foliage layer XML parsing (synthetic fixture):")
    from ge_mcp.tools.terrain import _resolve_map_path
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        (td / "foliage").mkdir()
        (td / "foliage" / "grass.xml").write_text(
            '<foliageType><foliageLayer name="grass">'
            '<foliageState name="small"/><foliageState name="big"/>'
            '</foliageLayer></foliageType>', encoding="utf-8")
        p = _resolve_map_path("foliage/grass.xml", td)
        check("relative path resolves", p is not None and p.name == "grass.xml")
        check("missing path -> None", _resolve_map_path("nope/missing.xml", td) is None)
        if p:
            states = [fs.get("name") for fs in
                      ET.parse(p).getroot().findall("foliageLayer")[0].findall("foliageState")]
            check("states parsed", states == ["small", "big"], str(states))


# ---- config / game-dir resolution ---------------------------------------------
def test_config():
    print("config + game-dir resolution:")
    from ge_mcp import config as C
    check("normalize strips data/", C.normalize_game_dir(r"C:\fake\FS25\data").name == "FS25")
    check("normalize strips quotes", C.normalize_game_dir('"C:\\fake\\FS25"').name == "FS25")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        fake = td / "Farming Simulator 25"
        (fake / "data").mkdir(parents=True)
        check("looks_like_fs25 true", C.looks_like_fs25(fake))
        check("looks_like_fs25 false", not C.looks_like_fs25(td))
        # env var wins the chain
        old_env = os.environ.get("GE_GAME_DIR")
        os.environ["GE_GAME_DIR"] = str(fake)
        try:
            p, src = C.game_dir()
            check("env var wins", p == fake and "env" in src, f"{p} [{src}]")
            os.environ["GE_GAME_DIR"] = str(td)  # invalid: no data/ inside
            p2, src2 = C.game_dir()
            check("invalid env reported", p2 is None and "doesn't look like" in src2, src2)
        finally:
            if old_env is None:
                del os.environ["GE_GAME_DIR"]
            else:
                os.environ["GE_GAME_DIR"] = old_env
        # persisted config roundtrip (CONFIG_PATH redirected into the tmp dir)
        old_cfg = C.CONFIG_PATH
        C.CONFIG_PATH = td / "ge-mcp.config.json"
        try:
            C.set_value("game_dir", str(fake))
            check("config roundtrip", C.load().get("game_dir") == str(fake))
        finally:
            C.CONFIG_PATH = old_cfg
        # editor.xml parse (GE_APPDATA redirected onto a synthetic editor.xml)
        (td / "editor.xml").write_text(
            "<editor><game><gameinstallationpath>" + str(fake).replace("\\", "/")
            + "</gameinstallationpath></game></editor>", encoding="utf-8")
        old_appdata = C.GE_APPDATA
        C.GE_APPDATA = td
        try:
            check("editor.xml parse", C._from_editor_xml() == fake)
        finally:
            C.GE_APPDATA = old_appdata


# ---- setup: poller install --------------------------------------------------------
def test_poller_install():
    print("setup(install_poller): copies the poller into GE scripts dir:")
    from ge_mcp.tools import core as C
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        old = C.GE_APPDATA
        C.GE_APPDATA = td
        try:
            r = C.setup(install_poller=True)
            check("poller copied", (td / "scripts" / "ge_mcp_poller.lua").is_file(), r[:80])
            r2 = C.setup(install_poller=True)
            check("idempotent", "already installed" in r2, r2[:80])
        finally:
            C.GE_APPDATA = old


# ---- registration ------------------------------------------------------------------
def test_registration():
    print("group registration:")
    from ge_mcp.tools import GROUPS
    from ge_mcp.server import enabled_groups
    expected = {"core": 9, "splines": 5, "terrain": 11, "nodes": 13,
                "fields": 3, "hygiene": 3, "materials": 1, "traffic": 1,
                "assets": 2, "vision": 6, "scene": 2, "snippets": 3}
    for g, n in expected.items():
        check(f"group {g} has {n} tools", len(GROUPS[g].TOOLS) == n,
              str(len(GROUPS[g].TOOLS)))
    total = sum(len(m.TOOLS) for m in GROUPS.values())
    check("total 59", total == 59, str(total))
    old = os.environ.get("GE_MCP_GROUPS")
    try:
        os.environ["GE_MCP_GROUPS"] = "splines"
        picked = enabled_groups()
        check("GE_MCP_GROUPS filter + core forced",
              set(picked) == {"core", "splines"}, str(set(picked)))
        os.environ["GE_MCP_GROUPS"] = "all"
        check("all groups", len(enabled_groups()) == len(GROUPS))
        os.environ["GE_MCP_GROUPS"] = "bogus"
        try:
            enabled_groups()
            check("unknown group aborts", False)
        except SystemExit:
            check("unknown group aborts", True)
    finally:
        if old is None:
            del os.environ["GE_MCP_GROUPS"]
        else:
            os.environ["GE_MCP_GROUPS"] = old
    # every tool has a docstring (docgen + MCP descriptions depend on it)
    undocumented = [fn.__name__ for m in GROUPS.values() for fn in m.TOOLS if not fn.__doc__]
    check("every tool documented", not undocumented, str(undocumented))


if __name__ == "__main__":
    for t in (test_validator, test_marshalling, test_appdata, test_snippets,
              test_foliage_parse, test_config, test_poller_install, test_registration):
        t()
        print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S): " + ", ".join(FAILURES))
        sys.exit(1)
    print("ALL OFFLINE TESTS PASSED")
