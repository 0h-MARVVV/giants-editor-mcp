"""FastMCP server assembly: group registration + entry point.

GE_MCP_GROUPS (env var) selects which tool groups register, comma-separated:
  core, splines, terrain, nodes, vision, scene, snippets
Default: all. Example lean setup: GE_MCP_GROUPS=core,splines,nodes
Unknown group names abort at startup with the valid list (better than silently
running without the tools you expected).
"""

import os
import sys

from mcp.server.fastmcp import FastMCP

from .tools import GROUPS

mcp = FastMCP("giants-editor")


def enabled_groups():
    raw = (os.environ.get("GE_MCP_GROUPS") or "all").strip().lower()
    if raw in ("", "all", "*"):
        return dict(GROUPS)
    picked = {}
    bad = []
    for name in raw.split(","):
        name = name.strip()
        if not name:
            continue
        if name in GROUPS:
            picked[name] = GROUPS[name]
        else:
            bad.append(name)
    if bad:
        raise SystemExit("GE_MCP_GROUPS contains unknown group(s): " + ", ".join(bad)
                         + ". Valid: " + ", ".join(sorted(GROUPS)) + ", or 'all'.")
    # core is the bridge itself -- without it nothing else can be debugged
    picked.setdefault("core", GROUPS["core"])
    return picked


def register_all(target=None):
    """Register enabled groups on the FastMCP instance. Returns {group: [tool names]}."""
    target = target or mcp
    registered = {}
    for name, mod in enabled_groups().items():
        mod.register(target)
        registered[name] = [fn.__name__ for fn in mod.TOOLS]
    return registered


def main():
    registered = register_all()
    total = sum(len(v) for v in registered.values())
    print(f"[ge-mcp] {total} tools in {len(registered)} group(s): "
          + ", ".join(sorted(registered)), file=sys.stderr)
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
