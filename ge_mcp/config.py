"""Per-machine configuration (ge-mcp.config.json next to the package, gitignored)
and FS25 game-directory resolution.

The game dir is needed to resolve `$data/...` references (foliage XMLs, asset
catalog). Resolution order, first hit wins:

  1. GE_GAME_DIR env var
  2. ge-mcp.config.json  (persisted via the `setup` tool)
  3. the editor's own preferences -- <gameinstallationpath> in editor.xml
     (every mapper sets this, or $data maps wouldn't load in GE)
  4. generic install-path probes
"""

import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path

from .bridge import GE_APPDATA

CONFIG_PATH = Path(__file__).resolve().parent.parent / "ge-mcp.config.json"

_PROBES = [
    Path("C:/Program Files (x86)/Steam/steamapps/common/Farming Simulator 25"),
    Path("C:/Program Files/Steam/steamapps/common/Farming Simulator 25"),
    Path("C:/Program Files/Epic Games/FarmingSimulator25"),
    Path("C:/Program Files/GIANTS Software/Farming Simulator 25"),
]


def load() -> dict:
    if not CONFIG_PATH.is_file():
        return {}
    try:
        d = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save(d: dict):
    CONFIG_PATH.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")


def set_value(key: str, value):
    d = load()
    d[key] = value
    save(d)


def looks_like_fs25(p: Path) -> bool:
    """An FS25 install has a data/ subdir (foliage, maps, shared, ...)."""
    return p.is_dir() and (p / "data").is_dir()


def normalize_game_dir(raw: str):
    """Accept the install dir OR its data/ subdir; return the install dir.

    Pure path logic -- existence is checked separately by looks_like_fs25."""
    p = Path(str(raw).strip().strip('"')).resolve()
    if p.name.lower() == "data" and p.parent != p:
        p = p.parent
    return p


def _from_editor_xml():
    xml = GE_APPDATA / "editor.xml"
    if not xml.is_file():
        return None
    try:
        root = ET.parse(xml).getroot()
    except Exception:
        return None
    for el in root.iter():
        if el.tag.lower() == "gameinstallationpath" and (el.text or "").strip():
            p = Path(el.text.strip())
            if looks_like_fs25(p):
                return p
    return None


def game_dir():
    """-> (Path or None, source description)."""
    env = os.environ.get("GE_GAME_DIR")
    if env:
        p = normalize_game_dir(env)
        if looks_like_fs25(p):
            return p, "GE_GAME_DIR env var"
        return None, "GE_GAME_DIR is set but doesn't look like an FS25 install: " + env
    saved = load().get("game_dir")
    if saved:
        p = Path(saved)
        if looks_like_fs25(p):
            return p, "saved config (ge-mcp.config.json)"
        # stale config entry: fall through to auto-detection
    p = _from_editor_xml()
    if p is not None:
        return p, "editor.xml (GE preferences)"
    for probe in _PROBES:
        if looks_like_fs25(probe):
            return probe, "common install path"
    return None, ("not found -- run setup(game_dir=...) with your "
                  "Farming Simulator 25 install path")
