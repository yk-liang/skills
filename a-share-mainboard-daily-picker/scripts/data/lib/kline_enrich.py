#!/usr/bin/env python3
"""K 线后处理：给 bars 加 MACD（DIF/DEA/HIST）+ 检测顶/底背驰。

输入：stdin 接收 dispatch::call kline 输出的完整 JSON
输出：stdout 同样结构 + 每根 bar 加 macd_dif/dea/hist + data 顶层加 macd_last + macd_divergence

为什么：缠论 ② — MACD 顶背驰是少数稳定的卖出预警信号（价格新高 + 柱体缩小）。
"""
import json
import sys


def ema(values, period):
    if not values:
        return []
    k = 2 / (period + 1)
    result = [values[0]]
    for i in range(1, len(values)):
        result.append(values[i] * k + result[-1] * (1 - k))
    return result


def compute_macd(closes, fast=12, slow=26, signal=9):
    ema_fast = ema(closes, fast)
    ema_slow = ema(closes, slow)
    dif = [f - s for f, s in zip(ema_fast, ema_slow)]
    dea = ema(dif, signal)
    hist = [(d - e) * 2 for d, e in zip(dif, dea)]
    return dif, dea, hist


def detect_divergence(closes, hist, lookback=60):
    """简化版背驰检测：在最近 lookback 根 K 内找 hist 的局部峰/谷，
    对照对应位置的 close — 价格新高/低但 hist 未跟上 → 背驰。
    """
    if len(closes) < 26 or len(hist) < 26:
        return {
            "top_divergence": False,
            "bottom_divergence": False,
            "reason": "数据不足 26 根 K（MACD warmup）",
        }

    eff_lookback = min(lookback, len(closes))
    window_close = closes[-eff_lookback:]
    window_hist = hist[-eff_lookback:]

    peaks = []
    troughs = []
    for i in range(1, len(window_hist) - 1):
        if (
            window_hist[i] > 0
            and window_hist[i] > window_hist[i - 1]
            and window_hist[i] > window_hist[i + 1]
        ):
            peaks.append({"idx": i, "hist": round(window_hist[i], 4), "close": window_close[i]})
        if (
            window_hist[i] < 0
            and window_hist[i] < window_hist[i - 1]
            and window_hist[i] < window_hist[i + 1]
        ):
            troughs.append({"idx": i, "hist": round(window_hist[i], 4), "close": window_close[i]})

    result = {
        "top_divergence": False,
        "bottom_divergence": False,
        "lookback_days": eff_lookback,
        "peaks_count": len(peaks),
        "troughs_count": len(troughs),
        "top_detail": None,
        "bottom_detail": None,
    }

    if len(peaks) >= 2:
        prev_p, last_p = peaks[-2], peaks[-1]
        if last_p["close"] > prev_p["close"] and last_p["hist"] < prev_p["hist"]:
            result["top_divergence"] = True
            result["top_detail"] = {
                "prev_peak": prev_p,
                "last_peak": last_p,
                "interpretation": "价格创新高但 MACD 柱体缩小 — 顶背驰（卖出预警）",
            }

    if len(troughs) >= 2:
        prev_t, last_t = troughs[-2], troughs[-1]
        if last_t["close"] < prev_t["close"] and last_t["hist"] > prev_t["hist"]:
            result["bottom_divergence"] = True
            result["bottom_detail"] = {
                "prev_trough": prev_t,
                "last_trough": last_t,
                "interpretation": "价格创新低但 MACD 柱体收敛 — 底背驰（买入预警）",
            }

    return result


def find_zhongshu(highs, lows, n_recent=30):
    """简化版缠论中枢识别：最近 N 根 K 内找局部分型 → 重叠区即中枢。

    完整缠论中枢需先做笔/线段分解，本版本是实战简化：
    - 顶分型 = 中间 K 的 high > 左右两根 high
    - 底分型 = 中间 K 的 low < 左右两根 low
    - 中枢上沿 = 最近 3-5 个顶分型的最小值
    - 中枢下沿 = 最近 3-5 个底分型的最大值
    - 若上沿 ≤ 下沿 → 无中枢（趋势中，不是盘整）
    """
    if len(highs) < n_recent or len(lows) < n_recent:
        return None

    h_window = highs[-n_recent:]
    l_window = lows[-n_recent:]

    fenxing = []
    for i in range(1, len(h_window) - 1):
        if h_window[i] > h_window[i - 1] and h_window[i] > h_window[i + 1]:
            fenxing.append({"idx": i, "type": "top", "price": h_window[i]})
        if l_window[i] < l_window[i - 1] and l_window[i] < l_window[i + 1]:
            fenxing.append({"idx": i, "type": "bottom", "price": l_window[i]})

    if len(fenxing) < 3:
        return None

    recent_fx = fenxing[-5:] if len(fenxing) >= 5 else fenxing[-3:]
    tops = [f["price"] for f in recent_fx if f["type"] == "top"]
    bottoms = [f["price"] for f in recent_fx if f["type"] == "bottom"]

    if not tops or not bottoms:
        return None

    upper = min(tops)
    lower = max(bottoms)
    if upper <= lower:
        return {
            "valid": False,
            "reason": "无重叠区 — 当前在趋势段中（非盘整）",
            "fenxing_count": len(recent_fx),
        }

    return {
        "valid": True,
        "upper": round(upper, 2),
        "lower": round(lower, 2),
        "midpoint": round((upper + lower) / 2, 2),
        "height_pct": round((upper - lower) / lower * 100, 2),
        "fenxing_count": len(recent_fx),
        "n_recent_bars": n_recent,
    }


def detect_chanlun_levels(closes, highs, lows, zhongshu, macd_div):
    """检测当前所处的缠论买卖点类型（多个可能并存）"""
    if not closes:
        return []

    current = closes[-1]
    levels = []

    if macd_div.get("bottom_divergence"):
        levels.append({
            "type": "一类买点",
            "reason": "MACD 底背驰 — 下跌趋势末端",
            "risk": "高（抄底有可能继续跌；建议等二买确认）",
            "stop_loss_hint": "跌破最近 bottom_divergence.last_trough.close 即止损",
        })

    if macd_div.get("top_divergence"):
        levels.append({
            "type": "一类卖点",
            "reason": "MACD 顶背驰 — 上涨趋势末端，必须减仓",
            "risk": "中（一卖应果断；卖飞是成本不是错误）",
            "stop_loss_hint": "不适用（卖出动作）",
        })

    if zhongshu and zhongshu.get("valid"):
        upper = zhongshu["upper"]
        lower = zhongshu["lower"]

        if len(highs) >= 10:
            recent_high = max(highs[-10:])
            if recent_high > upper and upper <= current <= upper * 1.03:
                levels.append({
                    "type": "三类买点",
                    "reason": f"突破中枢上沿 {upper:.2f} 后回踩（容差 ≤3%）— 当前 {current:.2f}",
                    "risk": "中（趋势延续型，A 股主板最稳定买点之一）",
                    "stop_loss_hint": f"跌破 {upper:.2f}（中枢上沿）即止损",
                })

        if len(lows) >= 10:
            recent_low = min(lows[-10:])
            if recent_low < lower and lower * 0.97 <= current <= lower:
                levels.append({
                    "type": "三类卖点",
                    "reason": f"跌破中枢下沿 {lower:.2f} 后反弹未过 — 当前 {current:.2f}",
                    "risk": "高（下跌趋势确认，应清仓）",
                    "stop_loss_hint": "不适用（卖出动作）",
                })

    return levels


def enrich(payload):
    data = payload.get("data") or {}
    bars = data.get("bars") or []
    if not bars:
        return payload

    closes = [b.get("close") for b in bars if b.get("close") is not None]
    highs  = [b.get("high")  for b in bars if b.get("high")  is not None]
    lows   = [b.get("low")   for b in bars if b.get("low")   is not None]
    if len(closes) < 26:
        data["macd_warmup_required"] = True
        return payload

    dif, dea, hist = compute_macd(closes)

    bars_with_close = [b for b in bars if b.get("close") is not None]
    for i, bar in enumerate(bars_with_close):
        if i < len(dif):
            bar["macd_dif"] = round(dif[i], 4)
            bar["macd_dea"] = round(dea[i], 4)
            bar["macd_hist"] = round(hist[i], 4)

    if len(dif) >= 2:
        prev_above = dif[-2] > dea[-2]
        now_above = dif[-1] > dea[-1]
        if now_above and not prev_above:
            trend = "金叉"
        elif not now_above and prev_above:
            trend = "死叉"
        elif now_above:
            trend = "多头"
        else:
            trend = "空头"
    else:
        trend = "数据不足"

    data["macd_last"] = {
        "dif": round(dif[-1], 4),
        "dea": round(dea[-1], 4),
        "hist": round(hist[-1], 4),
        "trend": trend,
    }
    divergence = detect_divergence(closes, hist)
    data["macd_divergence"] = divergence

    # 缠论 ④ 中枢识别 + ① 三类买卖点
    if len(highs) >= 30:
        zhongshu = find_zhongshu(highs, lows, n_recent=30)
        data["zhongshu"] = zhongshu
        data["chanlun_levels"] = detect_chanlun_levels(closes, highs, lows, zhongshu, divergence)
    else:
        data["zhongshu"] = None
        data["chanlun_levels"] = []

    return payload


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        sys.exit(1)
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        sys.stdout.write(raw)
        return
    enriched = enrich(payload)
    sys.stdout.write(json.dumps(enriched, ensure_ascii=False))


if __name__ == "__main__":
    main()
