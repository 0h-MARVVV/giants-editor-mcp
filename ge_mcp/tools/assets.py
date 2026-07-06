"""Game-asset catalog ($data) and mod validation -- mostly disk-side.

The FS25 install is resolved via config.game_dir() (setup tool). The i3d
catalog is walked once per server process and cached.
"""

import re
import xml.etree.ElementTree as ET
from pathlib import Path

from .. import config
from ..bridge import bridge
from ..helpers import call_helper, int_or_str

_CATALOG = {"root": None, "files": None}


def _game_data():
    gd, src = config.game_dir()
    if gd is None:
        return None, "[ERR] game dir not found -- run setup(game_dir=...). (" + src + ")"
    return gd / "data", None


def _catalog():
    data, err = _game_data()
    if err:
        return None, err
    if _CATALOG["files"] is not None and _CATALOG["root"] == str(data):
        return _CATALOG["files"], None
    files = [p.relative_to(data).as_posix() for p in data.rglob("*.i3d")]
    _CATALOG["root"] = str(data)
    _CATALOG["files"] = files
    return files, None


def asset_ops(action: str, query: str = "", path: str = "", x: float = 0.0,
              z: float = 0.0, y: float = None, parent: str = "", name: str = "",
              limit: int = 40) -> str:
    """Browse and place base-game assets from $data -- one tool, action-routed:

    categories                 top-level $data folders with i3d counts
    search (query, [limit])    find i3ds by path substring(s), space-separated
                               terms all must match (e.g. 'tree birch', 'fence')
    info (path)                one i3d: root nodes, shape/light counts, files
    place (path, x, z, [y], [parent], [name])   import into the scene at the
                               position (y defaults to terrain height) -- the
                               catalog-to-map pipeline in one call

    `path` is $data-relative as returned by search. The catalog is cached per
    session. NOTE: base-game trees use SPECIES names -- search 'betula' not
    'birch', 'quercus'/'oak' both exist, 'pinus' for pines; try broad terms.
    """
    if action == "categories":
        files, err = _catalog()
        if err:
            return err
        counts = {}
        for f in files:
            top = f.split("/", 1)[0]
            counts[top] = counts.get(top, 0) + 1
        rows = ["  %-24s %5d i3d(s)" % (k, v) for k, v in sorted(counts.items(), key=lambda kv: -kv[1])]
        return str(len(files)) + " i3d(s) under $data:\n" + "\n".join(rows)

    elif action == "search":
        files, err = _catalog()
        if err:
            return err
        terms = [t for t in query.lower().split() if t]
        if not terms:
            return "[ERR] query required (space-separated terms, all must match)"
        hits = [f for f in files if all(t in f.lower() for t in terms)]
        if not hits:
            return "0 matches for '" + query + "'"
        out = [str(len(hits)) + " match(es) for '" + query + "':"]
        out += ["  " + h for h in hits[:limit]]
        if len(hits) > limit:
            out.append("  ... (" + str(len(hits) - limit) + " more; refine or raise limit)")
        return "\n".join(out)

    elif action == "info":
        data, err = _game_data()
        if err:
            return err
        p = (data / path.replace("$data/", "")).resolve()
        if not p.is_file():
            return "[ERR] not found under $data: " + path
        try:
            root = ET.parse(p).getroot()
        except Exception as exc:
            return "[ERR] parse failed: " + str(exc)
        scene = root.find("Scene")
        tops = []
        if scene is not None:
            for el in list(scene)[:12]:
                kids = len(list(el.iter())) - 1
                tops.append("  <%s name=\"%s\">%s" % (el.tag, el.get("name", "?"),
                            ("  +" + str(kids) + " nested") if kids else ""))
        shapes = len(root.findall(".//Shape"))
        lights = len(root.findall(".//Light"))
        nfiles = len(root.findall(".//Files/File"))
        return ("%s  (%.1f KB)\nroot nodes:\n%s\n%d Shape node(s), %d Light(s), %d file ref(s)"
                % (path, p.stat().st_size / 1024, "\n".join(tops) or "  (none)", shapes, lights, nfiles))

    elif action == "place":
        if not path:
            return "[ERR] path required (from search)"
        rel = path.replace("$data/", "")
        data, err = _game_data()
        if err:
            return err
        full = data / rel
        if not full.is_file():
            return "[ERR] not found under $data: " + path
        py = y
        if py is None:
            r = bridge("local t = g_terrainNode "
                       "if t == nil or not entityExists(t) then return 'noterr' end "
                       "return tostring(getTerrainHeightAtWorldPos(t, %r, 0, %r))" % (x, z), timeout=10.0)
            try:
                py = float((r.get("result") or "").strip())
            except ValueError:
                return "[ERR] could not resolve terrain height at (%s, %s): %s" % (x, z, r.get("result"))
        # loadI3DFile wants a real filesystem path ($data/ is a game-side
        # convention the editor Lua call does not resolve)
        return call_helper("importI3d", {
            "path": str(full).replace("\\", "/"),
            "parent": int_or_str(parent) if parent else None,
            "name": name or None, "x": x, "y": py, "z": z,
        })

    return "[ERR] unknown action '" + action + "'. Actions: categories, search, info, place"


def mod_ops(action: str, path: str = "") -> str:
    """Mod-level inspection and validation -- one tool, action-routed:

    desc ([path])              parse modDesc.xml: title, author, version, maps,
                               store items (path = mod folder; default: the
                               open map's mod)
    validate ([path])          modDesc sanity + every file it references vs
                               disk (icon, map config, store item XMLs)
    placeable_validate (path)  one placeable XML: root/type, base i3d resolves,
                               storeData present, FS22-era elements that FS25
                               REMOVED (e.g. feedingTrough) flagged
    fruit_types / fill_types   name lists from the game's maps config XMLs

    Built from real FS22->FS25 conversion experience -- run validate before
    zipping a mod, placeable_validate on converted placeables. For the full
    set of VALID elements/attributes of any FS25 XML type, use xml_schema
    (the game's own XSDs) rather than guessing.
    """
    if action in ("fruit_types", "fill_types"):
        return _game_types(action)
    if action == "placeable_validate":
        return _placeable_validate(path)
    mod = _find_mod_dir(path)
    if isinstance(mod, str):
        return mod
    if action == "desc":
        return _mod_desc(mod)
    if action == "validate":
        return _mod_validate(mod)
    return "[ERR] unknown action '" + action + "'. Actions: desc, validate, placeable_validate, fruit_types, fill_types"


def _find_mod_dir(path):
    if path:
        p = Path(path)
        if (p / "modDesc.xml").is_file():
            return p
        return "[ERR] no modDesc.xml in " + str(p)
    r = bridge("return getSceneFilename()", timeout=6.0)
    if not r["ok"] or not (r["result"] or "").strip():
        return "[ERR] no path given and the editor isn't answering for the open map"
    p = Path(r["result"].strip()).parent
    for _ in range(4):
        if (p / "modDesc.xml").is_file():
            return p
        p = p.parent
    return "[ERR] no modDesc.xml above the open map -- pass the mod folder explicitly"


def _mod_desc(mod):
    try:
        root = ET.parse(mod / "modDesc.xml").getroot()
    except Exception as exc:
        return "[ERR] modDesc.xml parse failed: " + str(exc)
    def txt(tag):
        el = root.find(tag)
        if el is None:
            return "?"
        if len(el) > 0:                       # l10n children like <en>
            return (el[0].text or "?").strip()
        return (el.text or "?").strip()
    maps = [m.get("configFilename", "?") for m in root.findall(".//map")]
    store = root.findall(".//storeItem")
    return ("mod: " + mod.name
            + "\ntitle: " + txt("title") + "   author: " + txt("author")
            + "   version: " + txt("version")
            + "\ndescVersion: " + (root.get("descVersion") or "?")
            + "\nmaps: " + (", ".join(maps) or "(none)")
            + "\nstoreItems: " + str(len(store))
            + "\nicon: " + (root.findtext("iconFilename") or "?"))


def _mod_validate(mod):
    try:
        root = ET.parse(mod / "modDesc.xml").getroot()
    except Exception as exc:
        return "[ERR] modDesc.xml parse failed: " + str(exc)
    issues = []
    if not root.get("descVersion"):
        issues.append("  modDesc has no descVersion attribute")
    for tag in ("title", "author", "version"):
        if root.find(tag) is None:
            issues.append("  missing <" + tag + ">")
    swap = {".png": ".dds", ".dds": ".png"}

    def exists(rel):
        p = mod / rel.replace("\\", "/")
        if p.is_file():
            return True
        alt = swap.get(p.suffix.lower())
        return alt is not None and p.with_suffix(alt).is_file()

    icon = root.findtext("iconFilename")
    if icon and not exists(icon.strip()):
        issues.append("  icon missing on disk: " + icon.strip())
    checked = 0
    for m in root.findall(".//map"):
        cf = m.get("configFilename")
        if cf:
            checked += 1
            if not exists(cf):
                issues.append("  map config missing: " + cf)
    for si in root.findall(".//storeItem"):
        xf = si.get("xmlFilename")
        if xf:
            checked += 1
            if not exists(xf):
                issues.append("  storeItem xml missing: " + xf)
    head = "mod validate " + mod.name + ": modDesc + " + str(checked) + " referenced file(s) checked"
    if not issues:
        return head + " -- no problems found"
    return head + ", " + str(len(issues)) + " issue(s):\n" + "\n".join(issues)


# FS22-era placeable elements that FS25 removed/replaced (conversion recipe)
_FS25_REMOVED = ["feedingTrough", "markerIcons", "dynamicallyLoadedParts"]


def _placeable_validate(path):
    if not path:
        return "[ERR] path to a placeable xml required"
    p = Path(path)
    if not p.is_file():
        return "[ERR] not found: " + path
    try:
        root = ET.parse(p).getroot()
    except Exception as exc:
        return "[ERR] parse failed: " + str(exc)
    issues = []
    if root.tag != "placeable":
        issues.append("  root tag is <" + root.tag + ">, expected <placeable>")
    if not root.get("type"):
        issues.append("  <placeable> has no type attribute")
    base = root.findtext("base/filename")
    if base:
        bp = p.parent / base.replace("\\", "/")
        if not bp.is_file() and not base.startswith("$"):
            issues.append("  base i3d missing on disk: " + base)
    else:
        issues.append("  no <base><filename> (placeable i3d)")
    if root.find("storeData") is None:
        issues.append("  no <storeData> (name/price/store category)")
    text = p.read_text(encoding="utf-8", errors="replace")
    for tag in _FS25_REMOVED:
        if re.search(r"<\s*" + tag + r"[\s>]", text):
            issues.append("  contains <" + tag + "> -- removed in FS25 (conversion leftover)")
    head = "placeable_validate " + p.name + " (type=" + (root.get("type") or "?") + ")"
    if not issues:
        return head + " -- looks FS25-clean"
    return head + ": " + str(len(issues)) + " issue(s):\n" + "\n".join(issues)


def _game_types(action):
    data, err = _game_data()
    if err:
        return err
    fname = "maps_fruitTypes.xml" if action == "fruit_types" else "maps_fillTypes.xml"
    candidates = list((data / "maps").glob(fname)) + list(data.rglob(fname))
    for c in candidates:
        try:
            root = ET.parse(c).getroot()
        except Exception:
            continue
        tag = "fruitType" if action == "fruit_types" else "fillType"
        names = []
        for el in root.iter(tag):
            nm = el.get("name")
            if not nm:                       # FS25 style: filename ref, name = basename
                fn = el.get("filename") or ""
                nm = Path(fn).stem if fn else None
            if nm:
                names.append(nm)
        if names:
            return (str(len(names)) + " " + tag + "(s) from " + c.relative_to(data).as_posix()
                    + ":\n  " + ", ".join(sorted(names)))
    return "[ERR] " + fname + " not found/parsable under $data"


# ---- FS25 XML schema reference (shared/xml -- unencrypted, every install) ------
_XSD_NS = "{http://www.w3.org/2001/XMLSchema}"


def xml_schema(action: str = "list", name: str = "", element: str = "",
               depth: int = 4, limit: int = 120) -> str:
    """The GROUND TRUTH for FS25 XML: the game's own schemas from
    <game>/shared/xml/schema (88 XSDs -- placeable, vehicle, fields, farmlands,
    foliageType, fillTypes, fence, ...). CONSULT THIS before writing or editing
    any FS25 XML instead of guessing element/attribute names. Actions:

    list                 every schema file available
    show (name)          element tree of one schema: every element with its
                         attributes, types, enums, required flags
    show (name, element) just the subtree of elements whose name contains
                         `element` (use for huge schemas like vehicle)

    Matching human-readable HTML lives in <game>/shared/xml/documentation.
    Types shown are GIANTS' own (Float, Angle, 'String or l10n key', enums
    listed inline). depth/limit cap the outline; refine with `element`.
    """
    data, err = _game_data()
    if err:
        return err
    xml_dir = data.parent / "shared" / "xml" / "schema"
    if not xml_dir.is_dir():
        return "[ERR] schema folder not found: " + str(xml_dir)

    if action == "list":
        names = sorted(p.stem for p in xml_dir.glob("*.xsd"))
        return (str(len(names)) + " FS25 XML schema(s) in shared/xml/schema "
                "(xml_schema show <name> for the element tree):\n  "
                + ", ".join(names))

    if action != "show":
        return "[ERR] unknown action '" + action + "'. Actions: list, show"
    if not name:
        return "[ERR] name required (see action=list)"
    path = xml_dir / (name if name.endswith(".xsd") else name + ".xsd")
    if not path.is_file():
        cands = [p.stem for p in xml_dir.glob("*.xsd") if name.lower() in p.stem.lower()]
        if len(cands) == 1:
            path = xml_dir / (cands[0] + ".xsd")
        else:
            return ("[ERR] no schema '" + name + "'"
                    + (". Close matches: " + ", ".join(cands[:8]) if cands else ". See action=list"))
    try:
        root = ET.parse(path).getroot()
    except Exception as exc:
        return "[ERR] parse failed: " + str(exc)

    # simpleType name -> human description (GIANTS typeStr or enum values)
    types = {}
    for st in root.findall(_XSD_NS + "simpleType"):
        nm = st.get("name")
        if not nm:
            continue
        enums = [e.get("value") for e in st.iter(_XSD_NS + "enumeration")]
        if enums:
            types[nm] = "[" + "|".join(enums[:12]) + ("|..." if len(enums) > 12 else "") + "]"
            continue
        desc = None
        for ai in st.iter(_XSD_NS + "appinfo"):
            for child in ai:
                if child.tag.endswith("typeStr") and (child.text or "").strip():
                    desc = child.text.strip()
        types[nm] = desc or nm.replace("g_", "")

    def type_str(t):
        if not t:
            return "?"
        return types.get(t, t.replace("xs:", ""))

    named_ct = {ct.get("name"): ct for ct in root.findall(_XSD_NS + "complexType") if ct.get("name")}
    focus = element.lower().strip()
    lines, clipped = [], [False]

    def emit(s):
        if len(lines) >= limit:
            clipped[0] = True
            return False
        lines.append(s)
        return True

    def walk(el, path_str, d, forced):
        nm = el.get("name") or el.get("ref") or "?"
        here = (path_str + "." + nm) if path_str else nm
        hit = not focus or focus in nm.lower() or forced
        ct = None
        t = el.get("type")
        if t and t in named_ct:
            ct = named_ct[t]
        for child in el:
            if child.tag == _XSD_NS + "complexType":
                ct = child
        if hit:
            attrs = []
            if ct is not None:
                # direct children only -- iter() would hoover up every nested
                # element's attributes into the parent line
                for a in ct.findall(_XSD_NS + "attribute"):
                    astr = a.get("name") + "=" + type_str(a.get("type"))
                    if a.get("use") == "required":
                        astr += " (required)"
                    if a.get("default") is not None:
                        astr += " (default " + a.get("default") + ")"
                    attrs.append(astr)
            occurs = ""
            if el.get("maxOccurs") == "unbounded":
                occurs = "  (repeatable)"
            elif el.get("minOccurs") == "0":
                occurs = "  (optional)"
            if not emit("  " * min(d, 8) + "<" + nm + ">" + occurs):
                return
            for a in attrs:
                if not emit("  " * min(d, 8) + "   @" + a):
                    return
        if ct is not None and d < depth:
            for seq in ct:
                if seq.tag in (_XSD_NS + "sequence", _XSD_NS + "choice", _XSD_NS + "all"):
                    for sub in seq:
                        if sub.tag == _XSD_NS + "element":
                            walk(sub, here, d + 1, hit and bool(focus))

    for top in root.findall(_XSD_NS + "element"):
        walk(top, "", 0, False)

    if not lines:
        return ("no elements match '" + element + "' in " + path.stem
                + " at depth " + str(depth) + " -- try a different element or higher depth")
    head = (path.stem + ".xsd" + (" (elements matching '" + element + "')" if focus else "")
            + " -- depth " + str(depth) + ":")
    tail = ("\n  ... (output capped at " + str(limit) + " lines; use element= to narrow, "
            "or raise limit/depth)") if clipped[0] else ""
    return head + "\n" + "\n".join(lines) + tail


TOOLS = [asset_ops, mod_ops, xml_schema]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
