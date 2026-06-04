#!/usr/bin/env python3
"""
AKShare adapter helper — 被 lib/akshare.sh 调用，输出统一 schema JSON 到 stdout。

用法：
    python3 akshare_helper.py <endpoint> [args...]

支持的 endpoint：
    kline <code> [days=60] [period=1d]
    dragon_tiger [date=YYYY-MM-DD]
    north_flow
    financials_full <code>      # 完整三表，比 eastmoney financials 多 13 倍历史
    earnings_forecast [date=YYYYMMDD]
    individual_info <code>      # 流通股/市值/行业/上市时间
    limit_up_pool [date=YYYYMMDD]

设计原则：
- 失败时 exit 非零，stderr 写 error，stdout 留空
- 成功时 stdout 输出 {meta:{source,endpoint,...},data:{...}} JSON
- 不在脚本里编造数据；akshare 抛错就把错误透传
"""

import sys
import json
import time
import warnings
from datetime import datetime, timezone, timedelta

# 抑制 akshare 偶尔的 future warning
warnings.filterwarnings('ignore')

CST = timezone(timedelta(hours=8))


def _iso_now():
    return datetime.now(CST).isoformat(timespec='seconds')


def _trading_date():
    return datetime.now(CST).strftime('%Y-%m-%d')


def wrap_meta(endpoint, symbol, data):
    return {
        "meta": {
            "source": "akshare",
            "endpoint": endpoint,
            "fetched_at": _iso_now(),
            "symbol": symbol if symbol else None,
            "trading_date": _trading_date(),
        },
        "data": data,
    }


def _fail(msg):
    print(f"akshare: {msg}", file=sys.stderr)
    sys.exit(1)


def kline(args):
    """K 线 + 5/10/20/60 均线 + 5D/20D/60D 涨幅 — fallback 给东财 push2his"""
    import akshare as ak
    if not args:
        _fail("kline: missing code argument")
    code = args[0]
    days = int(args[1]) if len(args) > 1 else 60
    period_arg = args[2] if len(args) > 2 else "1d"
    period_map = {"1d": "daily", "1w": "weekly", "1mo": "monthly",
                  "day": "daily", "week": "weekly", "month": "monthly"}
    period = period_map.get(period_arg, "daily")

    # 起止日期：粗算往前推 1.5x days 给周末/节假日缓冲
    end = datetime.now(CST).strftime('%Y%m%d')
    start_dt = datetime.now(CST) - timedelta(days=int(days * 1.6))
    start = start_dt.strftime('%Y%m%d')

    try:
        df = ak.stock_zh_a_hist(symbol=code, period=period, start_date=start, end_date=end, adjust="qfq")
    except Exception as e:
        _fail(f"kline failed for {code}: {e}")

    if df is None or len(df) == 0:
        _fail(f"kline returned empty for {code}")

    # 只取最近 N 根
    df = df.tail(days)
    bars = []
    for _, row in df.iterrows():
        bars.append({
            "date": str(row["日期"]),
            "open": float(row["开盘"]),
            "close": float(row["收盘"]),
            "high": float(row["最高"]),
            "low": float(row["最低"]),
            "volume_lots": int(row["成交量"]),
            "turnover_yuan": float(row["成交额"]),
            "amplitude_pct": float(row["振幅"]),
            "change_pct": float(row["涨跌幅"]),
            "turnover_rate_pct": float(row["换手率"]),
        })

    def avg(lst, n):
        if len(lst) < n:
            return None
        return round(sum(lst[-n:]) / n, 2)

    def chg(lst, n):
        if len(lst) < n + 1:
            return None
        prev = lst[-(n + 1)]
        if prev == 0:
            return None
        return round((lst[-1] - prev) / prev * 100, 2)

    closes = [b["close"] for b in bars]
    vols = [b["volume_lots"] for b in bars]
    data = {
        "symbol": code,
        "name": None,
        "period": period_arg,
        "bars": bars,
        "ma5": avg(closes, 5),
        "ma10": avg(closes, 10),
        "ma20": avg(closes, 20),
        "ma60": avg(closes, 60),
        "change_5d_pct": chg(closes, 5),
        "change_20d_pct": chg(closes, 20),
        "change_60d_pct": chg(closes, 60),
        "avg_volume_5d_lots": int(sum(vols[-5:]) / 5) if len(vols) >= 5 else None,
        "avg_volume_20d_lots": int(sum(vols[-20:]) / 20) if len(vols) >= 20 else None,
    }
    print(json.dumps(wrap_meta("kline", code, data), ensure_ascii=False))


def dragon_tiger(args):
    """龙虎榜 — 救场场景（我们 datacenter URL 经常返回 0）"""
    import akshare as ak
    date = args[0] if args else _trading_date()
    date_compact = date.replace("-", "")
    try:
        df = ak.stock_lhb_detail_em(start_date=date_compact, end_date=date_compact)
    except Exception as e:
        _fail(f"dragon_tiger failed: {e}")

    if df is None:
        df = []
    stocks = []
    for _, row in df.iterrows() if hasattr(df, 'iterrows') else []:
        stocks.append({
            "code": str(row.get("代码", "")),
            "name": str(row.get("名称", "")),
            "change_pct": float(row.get("涨跌幅") or 0),
            "net_buy_yuan": float(row.get("龙虎榜净买额") or 0),
            "buy_yuan": float(row.get("龙虎榜买入额") or 0),
            "sell_yuan": float(row.get("龙虎榜卖出额") or 0),
            "turnover_yuan": float(row.get("龙虎榜成交额") or 0),
            "reason": str(row.get("上榜原因", "")),
        })
    data = {
        "query_date": date,
        "total": len(stocks),
        "stocks": stocks,
    }
    print(json.dumps(wrap_meta("dragon_tiger", None, data), ensure_ascii=False))


def north_flow(args):
    """北向资金当日（升级版本：含上涨/下跌家数 + 指数涨跌）"""
    import akshare as ak
    try:
        df = ak.stock_hsgt_fund_flow_summary_em()
    except Exception as e:
        _fail(f"north_flow failed: {e}")

    if df is None or len(df) == 0:
        _fail("north_flow returned empty")

    rows = []
    for _, row in df.iterrows():
        rows.append({
            "trade_date": str(row.get("交易日", "")),
            "type": str(row.get("类型", "")),
            "channel": str(row.get("板块", "")),
            "direction": str(row.get("资金方向", "")),
            "status": int(row.get("交易状态") or 0),
            "net_buy_yi": float(row.get("成交净买额") or 0),     # 单位：亿
            "net_inflow_yi": float(row.get("资金净流入") or 0),  # 单位：亿
            "remaining_yi": float(row.get("当日资金余额") or 0),
            "up_count": int(row.get("上涨数") or 0),
            "flat_count": int(row.get("持平数") or 0),
            "down_count": int(row.get("下跌数") or 0),
            "related_index": str(row.get("相关指数", "")),
            "index_change_pct": float(row.get("指数涨跌幅") or 0),
        })

    # 提取核心北向净流入（沪股通 + 深股通方向 = 北向）
    hk2sh = next((r for r in rows if "沪股通" in r["channel"] and r["direction"] == "北向"), None)
    hk2sz = next((r for r in rows if "深股通" in r["channel"] and r["direction"] == "北向"), None)
    sh2hk = next((r for r in rows if "港股通(沪)" in r["channel"]), None)
    sz2hk = next((r for r in rows if "港股通(深)" in r["channel"]), None)

    # 检测北向资金停披情况（自 2024-08-19 起监管要求停止每日披露）
    north_status = (hk2sh or {}).get("status", 0)
    north_net = (hk2sh["net_buy_yi"] if hk2sh else 0) + (hk2sz["net_buy_yi"] if hk2sz else 0)
    deprecated = (north_status == 3) and (north_net == 0)
    notice = None
    if deprecated:
        notice = "北向资金每日数据 2024-08-19 起停止披露（监管规定），status=3 + net=0 是正常状态而非接口故障；请改用南向资金 / 龙虎榜机构席位 / 主板涨跌停比 作为外资动向代理"

    data = {
        "raw_rows": rows,
        "hk_to_sh_net_yi": hk2sh["net_buy_yi"] if hk2sh else None,
        "hk_to_sz_net_yi": hk2sz["net_buy_yi"] if hk2sz else None,
        "sh_to_hk_net_yi": sh2hk["net_buy_yi"] if sh2hk else None,
        "sz_to_hk_net_yi": sz2hk["net_buy_yi"] if sz2hk else None,
        "total_north_in_yi": north_net,
        "north_deprecated": deprecated,
        "deprecated_notice": notice,
        "ssec_up_count": hk2sh["up_count"] if hk2sh else None,
        "ssec_down_count": hk2sh["down_count"] if hk2sh else None,
        "ssec_change_pct": hk2sh["index_change_pct"] if hk2sh else None,
        "szse_up_count": hk2sz["up_count"] if hk2sz else None,
        "szse_down_count": hk2sz["down_count"] if hk2sz else None,
    }
    print(json.dumps(wrap_meta("north_flow", None, data), ensure_ascii=False))


def financials_full(args):
    """完整三表 — 资产负债 / 利润 / 现金流。"""
    import akshare as ak
    if not args:
        _fail("financials_full: missing code argument")
    code = args[0]
    # akshare 需要带交易所前缀
    prefix = "SH" if code.startswith(("6", "5", "9")) else "SZ"
    symbol = f"{prefix}{code}"

    out = {"symbol": code}
    try:
        bs = ak.stock_balance_sheet_by_report_em(symbol=symbol)
        if bs is not None and len(bs) > 0:
            # 仅取最近 8 期，避免输出过大
            bs = bs.head(8)
            out["balance_sheet"] = [
                {
                    "report_date": str(row.get("REPORT_DATE_NAME", "")),
                    "total_assets": float(row.get("TOTAL_ASSETS") or 0),
                    "total_liabilities": float(row.get("TOTAL_LIABILITIES") or 0),
                    "total_equity": float(row.get("TOTAL_EQUITY") or 0),
                }
                for _, row in bs.iterrows()
            ]
    except Exception as e:
        out["balance_sheet_error"] = str(e)

    try:
        ps = ak.stock_profit_sheet_by_report_em(symbol=symbol)
        if ps is not None and len(ps) > 0:
            ps = ps.head(8)
            out["profit_sheet"] = [
                {
                    "report_date": str(row.get("REPORT_DATE_NAME", "")),
                    "operate_income": float(row.get("OPERATE_INCOME") or 0),
                    "operate_cost": float(row.get("OPERATE_COST") or 0),
                    "net_profit": float(row.get("NETPROFIT") or 0),
                    "parent_netprofit": float(row.get("PARENT_NETPROFIT") or 0),
                    "deduct_parent_netprofit": float(row.get("DEDUCT_PARENT_NETPROFIT") or 0),
                }
                for _, row in ps.iterrows()
            ]
    except Exception as e:
        out["profit_sheet_error"] = str(e)

    try:
        cf = ak.stock_cash_flow_sheet_by_report_em(symbol=symbol)
        if cf is not None and len(cf) > 0:
            cf = cf.head(8)
            out["cash_flow"] = [
                {
                    "report_date": str(row.get("REPORT_DATE_NAME", "")),
                    "operating_cash_flow": float(row.get("NETCASH_OPERATE") or 0),
                    "investing_cash_flow": float(row.get("NETCASH_INVEST") or 0),
                    "financing_cash_flow": float(row.get("NETCASH_FINANCE") or 0),
                }
                for _, row in cf.iterrows()
            ]
    except Exception as e:
        out["cash_flow_error"] = str(e)

    print(json.dumps(wrap_meta("financials_full", code, out), ensure_ascii=False))


def earnings_forecast(args):
    """业绩预告 — 报告期 (YYYYMMDD 格式，季度末)"""
    import akshare as ak
    date = args[0] if args else "20260331"  # 默认最近季度末
    try:
        df = ak.stock_yjyg_em(date=date)
    except Exception as e:
        _fail(f"earnings_forecast failed: {e}")

    if df is None:
        df = []
    forecasts = []
    for _, row in df.iterrows() if hasattr(df, 'iterrows') else []:
        forecasts.append({
            "code": str(row.get("股票代码", "")),
            "name": str(row.get("股票简称", "")),
            "metric": str(row.get("预测指标", "")),
            "change_text": str(row.get("业绩变动", "")),
            "predicted_value": float(row.get("预测数值") or 0),
            "change_pct": float(row.get("业绩变动幅度") or 0),
            "reason": str(row.get("业绩变动原因", "") or ""),
            "forecast_type": str(row.get("预告类型", "")),
            "prev_year_value": float(row.get("上年同期值") or 0),
            "announce_date": str(row.get("公告日期", "")),
        })
    data = {
        "report_period": date,
        "total": len(forecasts),
        "forecasts": forecasts,
    }
    print(json.dumps(wrap_meta("earnings_forecast", None, data), ensure_ascii=False))


def individual_info(args):
    """个股基础信息：市值/行业/上市日期/总股本"""
    import akshare as ak
    if not args:
        _fail("individual_info: missing code argument")
    code = args[0]
    try:
        df = ak.stock_individual_info_em(symbol=code)
    except Exception as e:
        _fail(f"individual_info failed for {code}: {e}")
    if df is None or len(df) == 0:
        _fail(f"individual_info returned empty for {code}")

    info = {row["item"]: row["value"] for _, row in df.iterrows()}
    data = {
        "symbol": code,
        "name": str(info.get("股票简称", "")),
        "latest_price": float(info.get("最新", 0) or 0),
        "industry": str(info.get("行业", "")),
        "listing_date": str(info.get("上市时间", "")),
        "total_shares": float(info.get("总股本", 0) or 0),
        "floating_shares": float(info.get("流通股", 0) or 0),
        "total_mcap_yuan": float(info.get("总市值", 0) or 0),
        "floating_mcap_yuan": float(info.get("流通市值", 0) or 0),
    }
    print(json.dumps(wrap_meta("individual_info", code, data), ensure_ascii=False))


def _safe_num(v, cast=float, default=None):
    """安全数值转换：处理 pandas NaN / 空字符串 / None / 0 等各种值"""
    try:
        if v is None or v == "" or (isinstance(v, float) and v != v):  # NaN check
            return default
        return cast(v)
    except (ValueError, TypeError):
        return default


def broken_up_pool(args):
    """炸板池 — 今日触及涨停后被打开（市场情绪关键指标，同花顺 app 显示的"涨停打开"）"""
    import akshare as ak
    date = args[0] if args else _trading_date().replace("-", "")
    df = None
    last_err = None
    for attempt in range(2):
        try:
            df = ak.stock_zt_pool_zbgc_em(date=date)
            break
        except Exception as e:
            last_err = e
            time.sleep(2)
    if df is None:
        _fail(f"broken_up_pool failed after retry: {last_err}")

    if df is None:
        df = []
    stocks = []
    for _, row in df.iterrows() if hasattr(df, 'iterrows') else []:
        stocks.append({
            "code": str(row.get("代码", "")),
            "name": str(row.get("名称", "")),
            "price": _safe_num(row.get("最新价"), float),
            "limit_up_price": _safe_num(row.get("涨停价"), float),
            "change_pct": _safe_num(row.get("涨跌幅"), float),
            "turnover_yuan": _safe_num(row.get("成交额"), float),
            "circulating_mcap_yuan": _safe_num(row.get("流通市值"), float),
            "total_mcap_yuan": _safe_num(row.get("总市值"), float),
            "turnover_rate_pct": _safe_num(row.get("换手率"), float),
            "speed_pct": _safe_num(row.get("涨速"), float),
            "first_limit_up_time": str(row.get("首次封板时间", "") or ""),
            "intraday_break_count": _safe_num(row.get("炸板次数"), int),
            "amplitude_pct": _safe_num(row.get("振幅"), float),
            "industry": str(row.get("所属行业", "") or ""),
            "window_stat": str(row.get("涨停统计", "") or ""),
        })
    mainboard_prefixes = ("600", "601", "603", "605", "000", "001", "002", "003")
    data = {
        "query_date": date,
        "total": len(stocks),
        "stocks": stocks,
        "mainboard_count": len([s for s in stocks if s["code"].startswith(mainboard_prefixes)]),
        "high_break_count": len([s for s in stocks if (s["intraday_break_count"] or 0) >= 3]),
    }
    print(json.dumps(wrap_meta("broken_up_pool", None, data), ensure_ascii=False))


def limit_down_pool(args):
    """跌停池 — 救场场景（东财 getTopicDTPool 经常返回 rc:206/data:null 假死）"""
    import akshare as ak
    date = args[0] if args else _trading_date().replace("-", "")
    # akshare 内部偶发崩在某行字段为空（A 股盘后数据未结算完时），retry 一次
    df = None
    last_err = None
    for attempt in range(2):
        try:
            df = ak.stock_zt_pool_dtgc_em(date=date)
            break
        except Exception as e:
            last_err = e
            time.sleep(2)
    if df is None:
        _fail(f"limit_down_pool failed after retry: {last_err}")

    if df is None:
        df = []
    stocks = []
    for _, row in df.iterrows() if hasattr(df, 'iterrows') else []:
        cols = set(row.index) if hasattr(row, 'index') else set()
        stocks.append({
            "code": str(row.get("代码", "")),
            "name": str(row.get("名称", "")),
            "price": _safe_num(row.get("最新价"), float),
            "change_pct": _safe_num(row.get("涨跌幅"), float),
            "turnover_yuan": _safe_num(row.get("成交额"), float),
            "circulating_mcap_yuan": _safe_num(row.get("流通市值"), float),
            "total_mcap_yuan": _safe_num(row.get("总市值"), float),
            "turnover_rate_pct": _safe_num(row.get("换手率"), float),
            "industry": str(row.get("所属行业", "") or ""),
            "consecutive_limit_down": _safe_num(row.get("连续跌停"), int) if "连续跌停" in cols else None,
            "open_times": _safe_num(row.get("开板次数"), int) if "开板次数" in cols else None,
            "last_limit_down_time": str(row.get("最后封板时间", "") or ""),
        })
    mainboard_prefixes = ("600", "601", "603", "605", "000", "001", "002", "003")
    data = {
        "query_date": date,
        "total": len(stocks),
        "stocks": stocks,
        "mainboard_count": len([s for s in stocks if s["code"].startswith(mainboard_prefixes)]),
    }
    print(json.dumps(wrap_meta("limit_down_pool", None, data), ensure_ascii=False))


def limit_up_pool(args):
    """涨停池（akshare 备份；优先用 10jqka 拿中文 high_days）"""
    import akshare as ak
    date = args[0] if args else _trading_date().replace("-", "")
    try:
        df = ak.stock_zt_pool_em(date=date)
    except Exception as e:
        _fail(f"limit_up_pool failed: {e}")

    if df is None or len(df) == 0:
        data = {"query_date": date, "total": 0, "stocks": []}
        print(json.dumps(wrap_meta("limit_up_pool", None, data), ensure_ascii=False))
        return

    stocks = []
    for _, row in df.iterrows():
        # akshare 涨停统计字段 18/9 表示"18天9板"
        zttj = str(row.get("涨停统计", ""))
        consecutive = int(row.get("连板数") or 1)
        stocks.append({
            "code": str(row["代码"]),
            "name": str(row["名称"]),
            "price": float(row.get("最新价") or 0),
            "change_pct": float(row.get("涨跌幅") or 0),
            "turnover_yuan": float(row.get("成交额") or 0),
            "circulating_mcap_yuan": float(row.get("流通市值") or 0),
            "total_mcap_yuan": float(row.get("总市值") or 0),
            "turnover_rate_pct": float(row.get("换手率") or 0),
            "consecutive_limit_up": consecutive,
            "is_first_board": consecutive == 1,
            "today_intraday_breaks": int(row.get("炸板次数") or 0),
            "limit_funds_yuan": float(row.get("封板资金") or 0),
            "industry": str(row.get("所属行业", "")),
            "ladder_label": f"{consecutive}连板" if consecutive > 1 else "首板",
            "window_stat": zttj,  # akshare 原始"18/9"格式
        })
    mainboard_prefixes = ("600", "601", "603", "605", "000", "001", "002", "003")
    data = {
        "query_date": date,
        "total": len(stocks),
        "stocks": stocks,
        "mainboard_count": len([s for s in stocks if s["code"].startswith(mainboard_prefixes)]),
        "max_consecutive": max((s["consecutive_limit_up"] for s in stocks), default=0),
        "pure_streak_3plus_count": len([s for s in stocks if s["consecutive_limit_up"] >= 3]),
    }
    print(json.dumps(wrap_meta("limit_up_pool", None, data), ensure_ascii=False))


def north_flow_history(args):
    """北向资金历史每日数据 + 5/20/30 日累计净流入

    args: [days_back]  默认 30
    返回每日净买额 + 5/20/30 日累计 + 趋势判断
    """
    import akshare as ak
    days_back = int(args[0]) if args else 30

    try:
        df = ak.stock_hsgt_hist_em(symbol="北向资金")
    except Exception as e:
        _fail(f"north_flow_history failed: {e}")

    if df is None or len(df) == 0:
        _fail("north_flow_history returned empty")

    # 防御性字段名识别（akshare 字段中文名偶有变化）
    date_col = None
    net_col = None
    for c in df.columns:
        cs = str(c)
        if "日期" in cs and date_col is None:
            date_col = c
        if ("成交净买额" in cs or "当日成交净买额" in cs) and net_col is None:
            net_col = c
    if not net_col:
        for c in df.columns:
            if "净买额" in str(c):
                net_col = c
                break

    if not date_col or not net_col:
        _fail(f"north_flow_history: cannot locate date/net columns in {list(df.columns)}")

    df_sorted = df.sort_values(date_col, ascending=False).head(days_back)

    import math as _math
    daily = []
    nan_count = 0
    for _, row in df_sorted.iterrows():
        raw = row[net_col]
        try:
            net_val = float(raw)
            if _math.isnan(net_val):
                nan_count += 1
                net_val = None
        except (TypeError, ValueError):
            nan_count += 1
            net_val = None
        daily.append({
            "date": str(row[date_col]),
            "net_buy_yi": round(net_val, 2) if net_val is not None else None,
        })

    # 检测北向资金停披情况（自 2024-08-19 起监管要求停止每日披露）
    deprecated = nan_count >= len(daily) * 0.9
    notice = None
    if deprecated:
        notice = "北向资金每日数据 2024-08-19 起停止披露（监管规定），近期值全为 null 是正常状态；本端点保留用于历史回看"

    nets = [d["net_buy_yi"] for d in daily if d["net_buy_yi"] is not None]
    cum_5d  = round(sum(nets[:5]),  2) if len(nets) >= 5  else None
    cum_20d = round(sum(nets[:20]), 2) if len(nets) >= 20 else None
    cum_30d = round(sum(nets[:30]), 2) if len(nets) >= 30 else None

    if cum_5d is not None and cum_20d is not None:
        if cum_5d > 0 and cum_20d > 0:
            trend = "持续净流入"
        elif cum_5d > 0 and cum_20d < 0:
            trend = "短期转流入（20日仍净流出）"
        elif cum_5d < 0 and cum_20d > 0:
            trend = "短期转流出（20日仍净流入）"
        else:
            trend = "持续净流出"
    elif deprecated:
        trend = "数据已停披（2024-08-19 起）"
    else:
        trend = "数据不足"

    data = {
        "daily": daily,
        "cum_5d_yi":  cum_5d,
        "cum_20d_yi": cum_20d,
        "cum_30d_yi": cum_30d,
        "trend": trend,
        "days_returned": len(daily),
        "deprecated_notice": notice,
    }
    print(json.dumps(wrap_meta("north_flow_history", None, data), ensure_ascii=False))


def main():
    if len(sys.argv) < 2:
        _fail("usage: akshare_helper.py <endpoint> [args...]")
    endpoint = sys.argv[1]
    args = sys.argv[2:]
    handlers = {
        "kline": kline,
        "dragon_tiger": dragon_tiger,
        "north_flow": north_flow,
        "north_flow_history": north_flow_history,
        "financials_full": financials_full,
        "earnings_forecast": earnings_forecast,
        "individual_info": individual_info,
        "limit_up_pool": limit_up_pool,
        "limit_down_pool": limit_down_pool,
        "broken_up_pool": broken_up_pool,
    }
    handler = handlers.get(endpoint)
    if not handler:
        _fail(f"unknown endpoint: {endpoint} (available: {', '.join(handlers)})")
    handler(args)


if __name__ == "__main__":
    main()
