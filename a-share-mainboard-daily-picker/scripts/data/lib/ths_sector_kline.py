#!/usr/bin/env python3
"""同花顺板块K线获取 — 东财 push2his 被 IP 封时的独立 fallback。

用法：ths_sector_kline.py <board_name> [days=60]
  board_name: 板块中文名（从 sector_rank 输出的 name 字段取）

原理：
1. 拉同花顺概念/行业板块列表 → 按名称模糊匹配 → 拿到同花顺板块代码
2. 调 d.10jqka.com.cn K线接口拿日K数据
3. 输出统一 JSON schema（与 eastmoney sector_kline 输出兼容）
"""
import json
import re
import sys
import time
from datetime import datetime, timezone, timedelta

TZ = timezone(timedelta(hours=8))
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"


def _iso_now():
    return datetime.now(TZ).strftime("%Y-%m-%dT%H:%M:%S+08:00")


def _trading_date():
    now = datetime.now(TZ)
    if now.hour < 15:
        now = now - timedelta(days=1)
    while now.weekday() >= 5:
        now = now - timedelta(days=1)
    return now.strftime("%Y-%m-%d")


def _fetch_board_list():
    """拉同花顺全量板块映射 {name: 88xxxx_code}。

    来源：
    1. 概念板块列表页 (/gn/) — 页面 JS 里有 platecode+platename JSON（~294 个）
    2. 行业板块列表页 (/thshy/) — HTML 里有 881xxx 代码（~140 个）
    合计覆盖 ~430 个板块。
    """
    import requests
    headers = {"User-Agent": UA, "Referer": "http://q.10jqka.com.cn/"}
    mapping = {}

    # 1) 概念板块（从 gn 页面 JS 提取 platecode → platename 映射）
    try:
        resp = requests.get("http://q.10jqka.com.cn/gn/", headers=headers, timeout=15)
        if resp.status_code == 200:
            match = re.search(r"value='(\{.*?\})'", resp.text)
            if match:
                data = json.loads(match.group(1))
                for v in data.values():
                    if isinstance(v, dict) and "platecode" in v and "platename" in v:
                        mapping[v["platename"]] = v["platecode"]
    except Exception:
        pass

    # 2) 行业板块（从 thshy 页面提取 881xxx）
    try:
        resp = requests.get("http://q.10jqka.com.cn/thshy/", headers=headers, timeout=15)
        if resp.status_code == 200:
            codes = re.findall(r"/thshy/detail/code/(\d+)/", resp.text)
            names = re.findall(r"/thshy/detail/code/\d+/[^>]*>([^<]+)</a>", resp.text)
            seen = set()
            for code, name in zip(codes, names):
                n = name.strip()
                if n not in seen:
                    mapping[n] = code
                    seen.add(n)
    except Exception:
        pass

    return mapping


def _match_board(board_name, mapping):
    """模糊匹配板块名 → 同花顺代码。东财和同花顺板块命名不完全一致，需要多级匹配。"""
    if not board_name or not mapping:
        return None

    # 精确匹配
    if board_name in mapping:
        return mapping[board_name]

    # 去掉常见后缀/前缀再精确匹配
    for suffix in ["概念", "板块", "Ⅱ", "Ⅲ", "主材", "设备", "器件"]:
        stripped = board_name.replace(suffix, "")
        if stripped in mapping:
            return mapping[stripped]
        # 反向：同花顺名去掉后缀
        for name, code in mapping.items():
            if name.replace(suffix, "") == board_name or name.replace(suffix, "") == stripped:
                return code

    # 包含匹配（板块名是子串）
    for name, code in mapping.items():
        if board_name in name or name in board_name:
            return code

    # 最后手段：bigram 匹配（要求 ≥ 50% 的 query bigrams 命中，防误配）
    def bigrams(s):
        return set(s[i:i+2] for i in range(len(s) - 1)) if len(s) >= 2 else {s}

    clean = board_name.replace("概念", "").replace("板块", "").replace("Ⅱ", "").replace("Ⅲ", "")
    q_grams = bigrams(clean)
    if not q_grams:
        return None

    best_match = None
    best_score = 0
    best_name = ""
    for name, code in mapping.items():
        n_clean = name.replace("概念", "").replace("板块", "")
        n_grams = bigrams(n_clean)
        overlap = len(q_grams & n_grams)
        # 要求命中率 ≥ 50%（query 的 bigrams 中至少一半匹配上）
        if overlap > best_score and overlap >= max(2, len(q_grams) * 0.5):
            best_score = overlap
            best_match = code
            best_name = name

    return best_match


def _lookup_from_detail_page(board_name):
    """匹配失败时的兜底：去概念板块列表搜名称 → 从详情页拿 88xxxx 代码"""
    import requests
    headers = {"User-Agent": UA, "Referer": "http://q.10jqka.com.cn/"}

    try:
        resp = requests.get("http://q.10jqka.com.cn/gn/", headers=headers, timeout=15)
        if resp.status_code != 200:
            return None

        # 找名称最匹配的板块及其 30xxxx detail code
        detail_codes = re.findall(r"/gn/detail/code/(\d+)/[^>]*>([^<]+)</a>", resp.text)
        target_cid = None
        for cid, name in detail_codes:
            if board_name in name or name in board_name:
                target_cid = cid
                break
        # 松匹配：要求板块名整体是对方子串（不只是前2字）
        if not target_cid and len(board_name) >= 3:
            for cid, name in detail_codes:
                # 名称去掉"概念"后互为子串
                clean_q = board_name.replace("概念", "").replace("板块", "")
                clean_n = name.replace("概念", "").replace("板块", "")
                if len(clean_q) >= 3 and (clean_q in clean_n or clean_n in clean_q):
                    target_cid = cid
                    break

        if not target_cid:
            return None

        # 从详情页拿 88xxxx 行情代码
        detail_url = f"http://q.10jqka.com.cn/gn/detail/code/{target_cid}/"
        resp2 = requests.get(detail_url, headers=headers, timeout=10)
        if resp2.status_code != 200:
            return None
        codes_88 = re.findall(r"(88\d{4})", resp2.text)
        # 通常详情页里第一个 88xxxx 就是该板块的行情代码
        return codes_88[0] if codes_88 else None
    except Exception:
        return None


def _fetch_kline(ths_code, days=60):
    """从 d.10jqka.com.cn 拿行业板块日K（881xxx）"""
    import requests
    headers = {"User-Agent": UA, "Referer": "http://q.10jqka.com.cn/"}
    url = f"http://d.10jqka.com.cn/v6/line/bk_{ths_code}/01/last.js"

    resp = requests.get(url, headers=headers, timeout=15)
    if resp.status_code != 200:
        return None

    match = re.search(r"\((\{.*\})\)", resp.text)
    if not match:
        return None

    data = json.loads(match.group(1))
    raw_lines = data.get("data", "").split(";")
    board_name = data.get("name", "")

    bars = []
    for line in raw_lines:
        parts = line.split(",")
        if len(parts) < 7:
            continue
        try:
            bars.append({
                "date": f"{parts[0][:4]}-{parts[0][4:6]}-{parts[0][6:8]}",
                "open": float(parts[1]),
                "high": float(parts[2]),
                "low": float(parts[3]),
                "close": float(parts[4]),
                "volume_lots": int(float(parts[5])),
                "turnover_yuan": float(parts[6]),
            })
        except (ValueError, IndexError):
            continue

    return bars[-days:] if len(bars) > days else bars, board_name


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: ths_sector_kline.py <board_name> [days=60]"}), file=sys.stderr)
        sys.exit(1)

    board_name = sys.argv[1]
    days = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else 60

    mapping = _fetch_board_list()
    if not mapping:
        print(f"10jqka: 板块列表获取失败", file=sys.stderr)
        sys.exit(1)

    ths_code = _match_board(board_name, mapping)
    if not ths_code:
        # 精确/模糊匹配都失败 — 尝试从概念板块详情页获取 88 代码
        ths_code = _lookup_from_detail_page(board_name)
    if not ths_code:
        print(f"10jqka: 板块名 '{board_name}' 未找到对应同花顺代码（共 {len(mapping)} 板块）", file=sys.stderr)
        sys.exit(1)

    if not ths_code.startswith("88"):
        print(f"10jqka: '{board_name}' 匹配到 {ths_code}（非88开头），无法拉K线。建议用龙头个股K线代替。", file=sys.stderr)
        sys.exit(2)

    result = _fetch_kline(ths_code, days)
    if not result:
        print(f"10jqka: 板块K线获取失败 (code={ths_code})", file=sys.stderr)
        sys.exit(1)

    bars, resolved_name = result

    output = {
        "meta": {
            "source": "10jqka",
            "endpoint": "sector_kline",
            "fetched_at": _iso_now(),
            "symbol": ths_code,
            "trading_date": _trading_date(),
        },
        "data": {
            "board_code": ths_code,
            "board_name": resolved_name or board_name,
            "query_name": board_name,
            "bars": bars,
        }
    }
    print(json.dumps(output, ensure_ascii=False))


if __name__ == "__main__":
    main()
