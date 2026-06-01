#!/usr/bin/env bash
# Finnhub adapter — 占位
#
# 现状（2026-06）：finnhub 免费 tier 对 A 股几乎全军覆没（K 线 Premium-only、quote 国际版仅 Enterprise、
# Company News 仅北美、Insider Transactions 不覆盖中国）。pricing 页 international OHLC 仅列 TSX/LSE/Euronext/德交。
#
# 因此本 adapter **不在 A 股工作流中被调用**。保留位置以便：
# 1. 用户后续若加美股/港股 skill，可以在那里 SOURCE=finnhub 直接复用
# 2. 给将来某些 finnhub 突然支持的字段（如全球指数）留口
#
# 使用前 export FINNHUB_TOKEN=xxx

set -euo pipefail

FH_TOKEN="${FINNHUB_TOKEN:-}"
FH_BASE="https://finnhub.io/api/v1"

fh::_iso_now() {
  if date "+%Y-%m-%dT%H:%M:%S%z" >/dev/null 2>&1; then
    date "+%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'
  else
    date -Iseconds
  fi
}

fh::_check_token() {
  if [ -z "$FH_TOKEN" ]; then
    echo "finnhub: FINNHUB_TOKEN env var not set" >&2
    return 1
  fi
}

fh::wrap_meta() {
  local endpoint="$1"
  local symbol="${2:-}"
  local data="$3"
  jq -n \
    --arg source "finnhub" \
    --arg endpoint "$endpoint" \
    --arg fetched_at "$(fh::_iso_now)" \
    --arg symbol "$symbol" \
    --argjson data "$data" \
    '{meta:{source:$source,endpoint:$endpoint,fetched_at:$fetched_at,symbol:(if ($symbol|length)>0 then $symbol else null end)},data:$data}'
}

fh::caps() {
  # 只声明已知免费 tier 能拿到、且对 A 股**有效**的能力。
  # 当前对 A 股：仅 stock_symbols（用于符号映射）。其他全部不可用。
  echo "stock_symbols"
}

fh::stock_symbols() {
  # GET /stock/symbol?exchange=SS|SZ
  fh::_check_token || return 1
  local exchange="${1:-SS}"
  local url="${FH_BASE}/stock/symbol?exchange=${exchange}&token=${FH_TOKEN}"
  local resp
  resp=$(curl -fsSL --max-time 15 "$url" 2>/dev/null) \
    || { echo "finnhub: stock_symbols failed for exchange=${exchange}" >&2; return 1; }
  fh::wrap_meta "stock_symbols" "" "$resp"
}

# 以下 endpoint 在 A 股上要么 Premium-only 要么不覆盖，调用前明确 fail，避免误用：
fh::quote()        { echo "finnhub: /quote does NOT support A-share on free tier; use eastmoney" >&2; return 1; }
fh::kline()        { echo "finnhub: /stock/candle is Premium-only AND A-share not in coverage list; use eastmoney" >&2; return 1; }
fh::index_quote()  { echo "finnhub: index quotes for SSE/SZSE not on free tier; use eastmoney" >&2; return 1; }
fh::announcements() { echo "finnhub: /company-news only available for North American companies; use cninfo" >&2; return 1; }
fh::financials()   { echo "finnhub: /stock/financials-reported uses SEC schema not applicable to A-share; use eastmoney" >&2; return 1; }
