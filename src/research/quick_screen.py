"""Fast pre-screen for universe candidates — yfinance only, no Claude API call.

Returns in ~2s per stock (up to ~2.7s for stocks that survive every free check
and reach the P/E lookup, which needs yfinance's slower full .info call).

Short economics (2026-08-20): this is the mirror image of AITrading's own
long-only pre-screen, which passed only "best of the best" bullish setups —
genuine uptrend on both time frames (price above both 50- and 200-day MA),
healthy momentum, and a real valuation ceiling. Left completely unmodified
through the earlier direction-fix passes this session (the R/R math, the
AI prompts, the buy-trigger logic), this filter was still passing ONLY
strong, uptrending, reasonably-valued companies into the pipeline — live-
caught the same day: 72 real candidates reached Claude on the first real
scan, every one got a real (non-fallback) analysis, and every one was
correctly declined as a short by the AI ("the fundamental case for a short
is weak," "does not support a conviction short") because the pre-filter
itself can only ever pass exactly the kind of company that's a poor short
candidate. The AI's judgment wasn't wrong; the pipeline was never showing
it a real short candidate to begin with.

Now looks for the mirror profile — a genuine DOWNTREND on both time frames
(price below both 50- and 200-day MA), momentum that isn't actively strong,
and a real valuation floor (expensive enough on a trailing P/E basis to have
genuine downside if it reverts toward a normal multiple). Liquidity and the
RSI "not at either extreme" band are kept unchanged from the original —
both are direction-neutral: a short-seller needs the same institutional-
quality liquidity a long buyer does, and a stock at either RSI extreme
(deeply oversold as much as overbought) carries real mean-reversion/
short-squeeze risk against a FRESH position regardless of which way that
position is headed.

Unlike the original's own P/E ceiling and momentum band (tuned live over
several iterations — v1 through v6 — against real R/R outcomes over time),
the mirrored valuation floor and momentum band below are a first-principles
best guess, not yet validated against real live outcomes the way the
original's numbers were. Expect these to need the same kind of live tuning
the original went through if they turn out too tight (nothing ever passes)
or too loose (candidates keep reaching Claude that are still, on inspection,
poor shorts)."""

import logging
import numpy as np
import yfinance as yf

logger = logging.getLogger(__name__)

_MIN_AVG_VOLUME = 3_000_000  # unchanged -- institutional-quality liquidity, direction-neutral
_RSI_HIGH = 65               # unchanged -- avoid either extreme (reversal/squeeze risk either way)
_RSI_LOW = 35                # unchanged -- avoid either extreme (reversal/squeeze risk either way)
_MOMENTUM_MAX_LOSS = 1.01    # mirror of the original's _MOMENTUM_MIN_GAIN=0.99 ("not actively
                             # weak" for a long candidate) -- "not actively strong" for a short
                             # candidate: allow up to a 1% GAIN over 20 days, reject anything
                             # stronger than that. Mirrors the same lesson the original's v6
                             # comment describes: a stock the market has already punished hard
                             # (strong recent NEGATIVE momentum, well-established downtrend) may
                             # already be efficiently priced for that decline, thinning the real
                             # margin of safety a fresh short would need -- same reasoning that
                             # led the original away from requiring strong momentum for a long.
_MIN_TRAILING_PE = 20        # mirror of the original's _MAX_TRAILING_PE=35 ("real valuation bar,
                             # not just not absurd") -- a floor instead of a ceiling: a trailing
                             # P/E below this isn't overvalued enough on its own to carry real
                             # downside if it reverts toward a normal multiple. Missing/negative
                             # P/E (e.g. a loss-making, richly-valued growth stock) is still NOT
                             # rejected here, same as the original -- that's a genuinely
                             # interesting short-candidate shape in its own right, left to the
                             # full Claude analysis rather than guessed at mechanically.


def _rsi(closes: np.ndarray, period: int = 14) -> float:
    if len(closes) < period + 1:
        return 50.0
    deltas = np.diff(closes)
    gains = np.where(deltas > 0, deltas, 0.0)
    losses = np.where(deltas < 0, -deltas, 0.0)
    # Wilder's EMA: seed with SMA of first period bars, then smooth
    avg_gain = gains[:period].mean()
    avg_loss = losses[:period].mean()
    for g, loss in zip(gains[period:], losses[period:]):
        avg_gain = (avg_gain * (period - 1) + g) / period
        avg_loss = (avg_loss * (period - 1) + loss) / period
    if avg_loss == 0:
        return 100.0
    return 100 - (100 / (1 + avg_gain / avg_loss))


def _pays_dividend(info_full: dict) -> bool:
    """True when a yfinance .info dict shows a real, nonzero dividend -- checks
    dividendRate (a dollar amount) and dividendYield (a decimal fraction) since either
    can be populated (or None/0) depending on the ticker; a stock with neither field
    set, or both falsy, doesn't pay one. Pure and separately tested (2026-08-20) since
    quick_screen() itself needs a live yfinance mock to exercise at all."""
    return bool(info_full.get("dividendRate") or info_full.get("dividendYield"))


def quick_screen(ticker: str, allow_dividend_stocks: bool = True) -> tuple[bool, str]:
    """Return (passes, reason). Synchronous — run in executor from async code.

    allow_dividend_stocks (2026-08-20, owner request): being short through an
    ex-dividend date means the short seller owes the dividend to whoever the
    shares were borrowed from -- a real cash cost this system doesn't model in
    P&L and Alpaca's paper account doesn't simulate either. When False, any
    ticker that pays a dividend is rejected here, before any Claude spend --
    never just flagged after the fact. Defaults to True (no filter) to match
    every scan's behavior before this setting existed."""
    try:
        t = yf.Ticker(ticker)
        info = t.fast_info

        avg_vol = getattr(info, "three_month_average_volume", 0) or 0
        if avg_vol < _MIN_AVG_VOLUME:
            return False, f"low volume ({avg_vol:,.0f} avg)"

        price = getattr(info, "last_price", None)
        if not price or price <= 0:
            return False, "no price data"

        # Short economics: only pass a genuine DOWNTREND on both time frames -- price
        # BELOW both the 50- and 200-day average, the mirror of the original's
        # above-both-MAs uptrend requirement.
        ma50 = getattr(info, "fifty_day_average", None)
        if ma50 and price > ma50:
            return False, f"above 50-day trend (${price:.2f} > 50-MA ${ma50:.2f})"

        ma200 = getattr(info, "two_hundred_day_average", None)
        if ma200 and price > ma200:
            return False, f"above long-term trend (${price:.2f} > 200-MA ${ma200:.2f})"

        hist = t.history(period="2mo", interval="1d")
        if hist.empty or len(hist) < 15:
            return False, "insufficient history"

        closes = hist["Close"].values
        rsi = _rsi(closes)

        if rsi > _RSI_HIGH:
            return False, f"overbought (RSI {rsi:.0f})"
        if rsi < _RSI_LOW:
            return False, f"oversold (RSI {rsi:.0f})"

        if len(closes) >= 20 and closes[-1] > closes[-20] * _MOMENTUM_MAX_LOSS:
            chg = (closes[-1] / closes[-20] - 1) * 100
            return False, f"too strong (${chg:+.1f}% vs 20d ago)"

        # P/E + dividend checks last — need yfinance's slower full .info call, so only
        # pay that cost for stocks that already survived every free/instant check above.
        try:
            info_full = t.info
        except Exception:
            info_full = {}

        if not allow_dividend_stocks and _pays_dividend(info_full):
            return False, "pays a dividend (excluded by setting)"

        pe = info_full.get("trailingPE")
        if pe is not None and pe < _MIN_TRAILING_PE:
            return False, f"not overvalued enough (P/E {pe:.0f})"

        return True, f"RSI {rsi:.0f} | vol {avg_vol / 1e6:.1f}M | downtrend confirmed"

    except Exception as e:
        logger.debug("Quick screen error for %s: %s", ticker, e)
        return False, "data error"
