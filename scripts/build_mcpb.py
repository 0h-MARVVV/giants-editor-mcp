"""Build the one-click Claude Desktop bundle: ge-mcp-<version>.mcpb

An .mcpb (MCP Bundle) is a zip with a manifest.json that Claude Desktop
installs by drag-and-drop -- no config editing. This builder packs the
runtime subset of the repo (no tests/scripts/gallery) plus a generated
manifest. Requires Python 3.10+ and `pip install mcp` on the target machine
(declared in the manifest description).

Run from the repo root:  python scripts/build_mcpb.py
Output lands next to the repo (D:/ClaudFolders equivalent on any machine).
"""

import json
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import ge_mcp  # noqa: E402

VERSION = ge_mcp.__version__

# runtime subset: what the server needs to run + read (docs kept light)
INCLUDE_PREFIXES = (
    "giants_mcp_server.py", "pyproject.toml", "LICENSE",
    "README.md", "INSTALL.md", "CHANGELOG.md",
    "ge_mcp/", "lua/", "snippets/", "known_functions.json",
)
EXCLUDE_SUBSTRINGS = ("__pycache__", ".full.json", "docs/img")

MANIFEST = {
    "manifest_version": "0.3",
    "name": "ge-mcp",
    "display_name": "GIANTS Editor bridge (FS25)",
    "version": VERSION,
    "description": ("Drive a live GIANTS Editor session: splines, terrain, fields, "
                    "audits, screenshots. Requires Python 3.10+ with `pip install mcp`, "
                    "GIANTS Editor 10.x and Farming Simulator 25."),
    "long_description": (
        "59 tools + a snippet library for FS25 map making in GIANTS Editor: "
        "place/paint/shape along splines, carve rivers, build fields from splines, "
        "validate traffic and file references, see the viewport from chat. "
        "After install: ask Claude to run `setup` with install_poller=true, start "
        "GIANTS Editor, load your map and run Scripts > GE-MCP Bridge once per session."),
    "author": {"name": "MARVVV"},
    "license": "MIT",
    "keywords": ["giants-editor", "farming-simulator", "fs25", "modding"],
    "server": {
        "type": "python",
        "entry_point": "giants_mcp_server.py",
        "mcp_config": {
            "command": "python",
            "args": ["${__dirname}/giants_mcp_server.py"],
            "env": {
                "GE_MCP_GROUPS": "${user_config.tool_groups}",
                "GE_GAME_DIR": "${user_config.game_dir}",
            },
        },
    },
    "user_config": {
        "tool_groups": {
            "type": "string",
            "title": "Tool groups",
            "description": ("Comma list of tool groups to enable, or 'all'. Groups: core, "
                            "splines, terrain, nodes, fields, hygiene, materials, traffic, "
                            "assets, vision, scene, snippets."),
            "required": False,
            "default": "all",
        },
        "game_dir": {
            "type": "directory",
            "title": "Farming Simulator 25 install (optional)",
            "description": ("Only needed if auto-detection fails -- normally found via the "
                            "editor's own preferences. Points at the folder containing data/."),
            "required": False,
            "default": "",
        },
    },
    "compatibility": {
        "platforms": ["win32"],
        "runtimes": {"python": ">=3.10"},
    },
}


def main():
    out = ROOT.parent / f"ge-mcp-{VERSION}.mcpb"
    # export the tracked tree via git (never picks up local-only files)
    files = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                           text=True, check=True).stdout.split()
    picked = [f for f in files
              if f.startswith(INCLUDE_PREFIXES)
              and not any(x in f for x in EXCLUDE_SUBSTRINGS)]
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(MANIFEST, indent=2, ensure_ascii=False))
        for f in picked:
            z.write(ROOT / f, f)
    size = out.stat().st_size
    print(f"wrote {out}  ({size / 1024:.0f} KB, {len(picked) + 1} files)")
    for check in ("giants_mcp_server.py", "ge_mcp/server.py", "lua/ge_mcp_poller.lua",
                  "lua/ge_mcp_helpers.lua", "known_functions.json", "pyproject.toml"):
        if check not in picked:
            print("  WARNING: expected file missing from bundle:", check)


if __name__ == "__main__":
    main()
