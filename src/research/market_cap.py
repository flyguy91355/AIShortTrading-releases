"""Shared market-cap tier classification (extracted 2026-08-24 from
src/research/engine.py, ported from AITrading's GitHub #82 fix).

Before this extraction, src/research/competitor.py's CompetitorAnalyzer._assess_position
had its own, independently-hardcoded set of market-cap bucket boundaries -- despite
engine.py's own _market_cap_tier_label docstring explicitly (and, it turned out,
incorrectly) claiming "Same bucket boundaries CompetitorAnalyzer._assess_position
already uses ... for consistency across the codebase." The two had drifted (engine.py:
mega-cap >= $200B; competitor.py: mega-cap >= $1T, with 6 tiers instead of 4) --
exactly the kind of duplicated-logic drift this codebase's own precedent (e.g.
_on_deck_ranking_key, _on_deck_composite_score) exists to prevent by having one shared
function instead of two independently-maintained copies.
"""


def market_cap_tier_label(market_cap: float) -> str:
    """Human-readable size tier for a market cap in dollars. Returns "" for a
    non-positive/unknown market cap so a caller can omit the context line entirely
    rather than asserting a tier it has no real data for."""
    if market_cap <= 0:
        return ""
    if market_cap >= 200_000_000_000:
        return "mega-cap"
    if market_cap >= 10_000_000_000:
        return "large-cap"
    if market_cap >= 2_000_000_000:
        return "mid-cap"
    return "small-cap"
