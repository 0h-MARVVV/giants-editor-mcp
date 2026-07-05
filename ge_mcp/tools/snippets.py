"""The snippet library: save proven run_lua scripts once, replay them forever.

Three schemas cover unlimited snippets -- the zero-marginal-cost tier of the
toolkit. snippets/ is plain JSON files, so packs can be shared between modders.
"""

from .. import snippets as lib


def save_snippet(name: str, lua: str, description: str = "", params: str = "",
                 overwrite: bool = False) -> str:
    """Save a Lua script that just proved itself, for cheap replay via run_snippet.

    name: 2-64 chars, a-z 0-9 _ - (e.g. 'select-high-clip-nodes').
    description: one line -- what it does and returns (shown by list_snippets).
    params: comma spec of the ARGS the script reads, defaults optional --
    e.g. 'width=3.0, layer=decoBush, count' (bare name = required). The script
    accesses them as ARGS.width etc.; run_snippet injects `local ARGS = {...}`.
    Records the GE version and tracks run/failure counts. Save deliberately:
    scripts that worked and will plausibly be wanted again -- not one-off probes.
    """
    return lib.save(name, lua, description, params, overwrite)


def run_snippet(name: str, args: str = "") -> str:
    """Run a saved snippet by name. args: 'width=5, layer=decoBush' or a JSON
    object; merged over the snippet's declared defaults (missing required args
    are refused). Bypasses the run_lua validator (the script was validated when
    saved); failures are recorded and flagged in list_snippets."""
    return lib.run(name, args)


def list_snippets(query: str = "") -> str:
    """List saved snippets: name(params) -- description [run stats].

    Check here BEFORE composing fresh Lua for a familiar-sounding task.
    Optional query filters name+description (case-insensitive)."""
    return lib.listing(query)


TOOLS = [save_snippet, run_snippet, list_snippets]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
