"""Generate docs/TOOLS.md from the registered tool functions' signatures and
docstrings. Run from the repo root:  python scripts/docgen.py"""

import inspect
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from ge_mcp.tools import GROUPS  # noqa: E402
import ge_mcp  # noqa: E402


def sig_line(fn):
    sig = inspect.signature(fn)
    parts = []
    for p in sig.parameters.values():
        if p.default is inspect.Parameter.empty:
            parts.append(p.name)
        else:
            d = p.default
            parts.append(f"{p.name}={d!r}" if isinstance(d, str) else f"{p.name}={d}")
    return fn.__name__ + "(" + ", ".join(parts) + ")"


def first_para(fn):
    doc = inspect.getdoc(fn) or ""
    return doc.split("\n\n")[0].replace("\n", " ").strip()


def main():
    out = ["# Tool reference", "",
           f"Generated from ge-mcp {ge_mcp.__version__} — do not edit by hand "
           "(run `python scripts/docgen.py`).", ""]
    total = 0
    for group in sorted(GROUPS):
        mod = GROUPS[group]
        out.append(f"## Group `{group}` ({len(mod.TOOLS)} tools)")
        out.append("")
        mod_doc = (inspect.getdoc(mod) or "").split("\n\n")[0].replace("\n", " ")
        if mod_doc:
            out.append(mod_doc)
            out.append("")
        for fn in mod.TOOLS:
            total += 1
            out.append(f"### `{sig_line(fn)}`")
            out.append("")
            out.append(first_para(fn))
            doc = inspect.getdoc(fn) or ""
            rest = doc.split("\n\n", 1)
            if len(rest) > 1 and rest[1].strip():
                out.append("")
                out.append(rest[1].strip())
            out.append("")
    out.insert(3, f"**{total} tools** in {len(GROUPS)} groups. "
                  "Toggle groups with the `GE_MCP_GROUPS` env var.")
    target = ROOT / "docs" / "TOOLS.md"
    target.write_text("\n".join(out), encoding="utf-8")
    print(f"wrote {target} ({total} tools, {len(GROUPS)} groups)")


if __name__ == "__main__":
    main()
