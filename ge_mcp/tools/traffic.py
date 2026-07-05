"""Traffic / AI spline validation (read-only)."""

from ..helpers import call_helper, int_or_str


def traffic_ops(action: str = "validate", node: str = "traffsplines",
                gap_tolerance: float = 1.0) -> str:
    """Traffic-spline checks -- read-only. Actions:

    list      every spline under the traffic root: length, closed flag
    validate  left/right pairing (missing partners), length mismatches >15%,
              direction DEVIANTS (the map's own majority pair-direction
              convention is detected first; only pairs that break it are
              flagged), and open endpoints with no other endpoint within
              gap_tolerance meters (dead ends that break AI traffic chains)

    node: the traffic root (default 'traffsplines'). Splines that fail these
    checks are the classic causes of in-game traffic vanishing or jamming.
    """
    return call_helper("trafficOps", {
        "action": action, "node": int_or_str(node),
        "gapTolerance": gap_tolerance,
    }, timeout=300.0)


TOOLS = [traffic_ops]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
