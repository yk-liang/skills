#!/usr/bin/env bash
# iTick adapter — 作为东财的官方稳定 fallback
#
# A 股能力（已确认）：
#   - quote / kline（1m/5m/15m/30m/1h/1d/1w/1M）
#   - indices quote / kline
#   - stock info（含 PE / 总市值 / 总股本）
#   - 符号清单
#
# A 股不支持（不实现，让 dispatcher fall through）：
#   涨停板池 / 跌停板池 / 龙虎榜 / 北向资金 / 概念板块榜 / 行业板块榜 / 板块成分股 / 板块 K
#   财务三表 / 巨潮原文公告 / 大股东减持
#
# 配额：免费 tier 5 req/min（很紧）— 仅在东财失败时作为 fallback 调
# 鉴权：export ITICK_TOKEN=xxx

set -euo pipefail

ITICK_TOKEN="${ITICK_TOKEN:-}"
ITICK_BASE="${ITICK_BASE:-https://api.itick.org}"

itick::_iso_now() {
  if date "+%Y-%m-%dT%H:%M:%S%z" >/dev/null 2>&1; then
    date "+%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'
  else
    date -Iseconds
  fi
}

itick::_check_token() {
  if [ -z "$ITICK_TOKEN" ]; then
    echo "itick: ITICK_TOKEN env var not set; export ITICK_TOKEN=xxx to enable" >&2
    return 1
  fi
}

itick::_get() {
  local url="$1"
  local resp
  resp=$(curl -fsSL --max-time 15 \
    -H "token: $ITICK_TOKEN" \
    -H "accept: application/json" \
    "$url" 2>/dev/null) || { echo "itick: GET failed: $url" >&2; return 1; }
  # iTick 统一响应：{code, msg, data}；code 非零即业务错误
  local code; code=$(printf '%s' "$resp" | jq -r '.code // -1')
  if [ "$code" != "0" ]; then
    local msg; msg=$(printf '%s' "$resp" | jq -r '.msg // "unknown"')
    echo "itick: business error code=$code msg=$msg url=$url" >&2
    return 1
  fi
  printf '%s' "$resp"
}

itick::wrap_meta() {
  local endpoint="$1"
  local symbol="${2:-}"
  local data="$3"
  jq -n \
    --arg source "itick" \
    --arg endpoint "$endpoint" \
    --arg fetched_at "$(itick::_iso_now)" \
    --arg symbol "$symbol" \
    --arg trading_date "$(date +%Y-%m-%d)" \
    --argjson data "$data" \
    '{meta:{source:$source,endpoint:$endpoint,fetched_at:$fetched_at,symbol:(if ($symbol|length)>0 then $symbol else null end),trading_date:$trading_date},data:$data}'
}

itick::caps() {
  echo "quote kline index_quote stock_symbols"
}

itick::_region_for() {
  # 600/601/603/605 → SH；000/001/002/003 → SZ
  case "$1" in
    6*) echo "SH" ;;
    0*|3*) echo "SZ" ;;
    *) echo "SH" ;;
  esac
}

itick::_index_region_code() {
  # iTick 指数代码：上证 SH:000001 / 深证 SZ:399001 / 创业板 SZ:399006
  case "$1" in
    sh|SH|sh000001|上证) echo "SH 000001" ;;
    sz|SZ|sz399001|深证) echo "SZ 399001" ;;
    cyb|CYB|创业板) echo "SZ 399006" ;;
    sh000300|沪深300) echo "SH 000300" ;;
    *) echo "" "" ;;
  esac
}

itick::quote() {
  itick::_check_token || return 1
  local code="$1"
  local region; region=$(itick::_region_for "$code")
  local url="${ITICK_BASE}/stock/quote?region=${region}&code=${code}"
  local resp; resp=$(itick::_get "$url") || return 1
  # iTick 字段（实测一般为）：t (timestamp)、o/h/l/c/p (open/high/low/close/prev_close)、v (volume)、tu (turnover)、cp (change pct)
  local data; data=$(printf '%s' "$resp" | jq --arg code "$code" '
    .data | {
      symbol: $code,
      price: (.c // .p // null),
      open: (.o // null),
      high: (.h // null),
      low: (.l // null),
      prev_close: (.pc // null),
      change: (.cn // null),
      change_pct: (.cp // null),
      volume_lots: (.v // null),
      turnover_yuan: (.tu // null),
      timestamp_ms: (.t // null)
    }')
  itick::wrap_meta "quote" "$code" "$data"
}

itick::kline() {
  itick::_check_token || return 1
  local code="$1"
  local days="${2:-60}"
  local period="${3:-1d}"
  local kt
  case "$period" in
    1d|day|D|d) kt=8 ;;
    1w|week|W|w) kt=9 ;;
    1mo|month|M) kt=10 ;;
    1m) kt=1 ;;
    5m) kt=2 ;;
    15m) kt=3 ;;
    30m) kt=4 ;;
    60m|1h) kt=5 ;;
    *) kt=8 ;;
  esac
  local region; region=$(itick::_region_for "$code")
  local url="${ITICK_BASE}/stock/kline?region=${region}&code=${code}&kType=${kt}&limit=${days}"
  local resp; resp=$(itick::_get "$url") || return 1
  local data; data=$(printf '%s' "$resp" | jq --arg code "$code" --arg period "$period" '
    {
      symbol: $code,
      period: $period,
      bars: ((.data // []) | map({
        timestamp_ms: .t,
        date: ((.t // 0) / 1000 | strftime("%Y-%m-%d")),
        open: .o,
        close: .c,
        high: .h,
        low: .l,
        volume_lots: .v,
        turnover_yuan: .tu
      }))
    } | . + {
      ma5: (
        if (.bars | length) >= 5 then
          (.bars[-5:] | map(.close) | add / 5 | . * 100 | round / 100)
        else null end
      ),
      ma10: (
        if (.bars | length) >= 10 then
          (.bars[-10:] | map(.close) | add / 10 | . * 100 | round / 100)
        else null end
      ),
      ma20: (
        if (.bars | length) >= 20 then
          (.bars[-20:] | map(.close) | add / 20 | . * 100 | round / 100)
        else null end
      ),
      ma60: (
        if (.bars | length) >= 60 then
          (.bars[-60:] | map(.close) | add / 60 | . * 100 | round / 100)
        else null end
      ),
      change_5d_pct: (
        if (.bars | length) >= 6 then
          (((.bars[-1].close - .bars[-6].close) / .bars[-6].close) * 10000 | round / 100)
        else null end
      ),
      change_20d_pct: (
        if (.bars | length) >= 21 then
          (((.bars[-1].close - .bars[-21].close) / .bars[-21].close) * 10000 | round / 100)
        else null end
      ),
      change_60d_pct: (
        if (.bars | length) >= 61 then
          (((.bars[-1].close - .bars[-61].close) / .bars[-61].close) * 10000 | round / 100)
        else null end
      )
    }')
  itick::wrap_meta "kline" "$code" "$data"
}

itick::index_quote() {
  itick::_check_token || return 1
  local idx="$1"
  local rc; rc=$(itick::_index_region_code "$idx")
  local region code
  read -r region code <<< "$rc"
  if [ -z "$region" ] || [ -z "$code" ]; then
    echo "itick: unknown index alias: $idx" >&2
    return 1
  fi
  local url="${ITICK_BASE}/indices/quote?region=${region}&code=${code}"
  local resp; resp=$(itick::_get "$url") || return 1
  local data; data=$(printf '%s' "$resp" | jq --arg sym "$code" '
    .data | {
      symbol: $sym,
      value: (.c // .p // null),
      open: (.o // null),
      high: (.h // null),
      low: (.l // null),
      prev_close: (.pc // null),
      change: (.cn // null),
      change_pct: (.cp // null),
      volume_lots: (.v // null),
      turnover_yuan: (.tu // null),
      timestamp_ms: (.t // null)
    }')
  itick::wrap_meta "index_quote" "$idx" "$data"
}

itick::stock_symbols() {
  itick::_check_token || return 1
  local region="${1:-SH}"
  local url="${ITICK_BASE}/symbol/list?region=${region}"
  local resp; resp=$(itick::_get "$url") || return 1
  itick::wrap_meta "stock_symbols" "" "$(printf '%s' "$resp" | jq '.data')"
}

# 不支持的（A 股专属衍生信号 + 财务）— 显式失败让 dispatcher fall through
itick::sector_rank()        { echo "itick: sector_rank not supported (no concept/industry boards)" >&2; return 1; }
itick::sector_constituents() { echo "itick: sector_constituents not supported" >&2; return 1; }
itick::sector_kline()       { echo "itick: sector_kline not supported" >&2; return 1; }
itick::limit_up_pool()      { echo "itick: limit_up_pool not supported (A-share specific)" >&2; return 1; }
itick::limit_down_pool()    { echo "itick: limit_down_pool not supported (A-share specific)" >&2; return 1; }
itick::north_flow()         { echo "itick: north_flow not supported (A-share specific)" >&2; return 1; }
itick::dragon_tiger()       { echo "itick: dragon_tiger not supported (A-share specific)" >&2; return 1; }
itick::announcements()      { echo "itick: announcements not supported (use cninfo)" >&2; return 1; }
itick::financials()         { echo "itick: financials (full statements) not supported (only PE/mcap available)" >&2; return 1; }
