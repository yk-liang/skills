#!/usr/bin/env bash
# Playwright adapter — 真浏览器 session + 同源 fetch，绕过 IP 风控
#
# 工作原理：复用 eastmoney.sh 的全部 URL 构建和 JSON 解析逻辑，只 override _get → 走浏览器
#
# 何时用：
# - sector_rank / sector_constituents / sector_kline（curl 风控时唯一救场）
# - quote / kline / index_quote（前三道防线全挂时）
# - 任何东财 push2/clist endpoint 被 IP 风控时
#
# 不实现的：
# - 同花顺、巨潮、akshare 的 endpoint（playwright 只接管东财通道）
#
# 人工验证模式：export PW_HEADED=1 → 浏览器可见，方便看 agent 真的抓到了什么
#
# 性能：启动 chromium ~1.5s + fetch ~0.5s = 单次 ~2s。比 agent-browser 快 50-100x

set -euo pipefail

# Source eastmoney.sh 拿全部 URL 构建 + jq 解析；下面 override _get/_now_ms 走浏览器
SCRIPT_DIR_PW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR_PW/eastmoney.sh"

# Override em::_get → 改走 playwright；保留 retry 逻辑
em::_get() {
  local url="$1"
  local tries=0
  local resp
  local headed_arg=""
  [ -n "${PW_HEADED:-}" ] && headed_arg="--headed"
  while [ $tries -lt 2 ]; do
    if resp=$(python3 "$SCRIPT_DIR_PW/pw_fetch.py" $headed_arg "$url" 2>/dev/null); then
      if [ -n "$resp" ]; then
        printf '%s' "$resp"
        return 0
      fi
    fi
    tries=$((tries + 1))
    sleep 1
  done
  echo "playwright: GET failed after retry: $url" >&2
  return 1
}

# Override em::wrap_meta → 把 source 改成 playwright（方便 agent 看到走了 fallback）
em::wrap_meta() {
  local endpoint="$1"
  local symbol="${2:-}"
  local data="$3"
  jq -n \
    --arg source "playwright" \
    --arg endpoint "$endpoint" \
    --arg fetched_at "$(em::_iso_now)" \
    --arg symbol "$symbol" \
    --arg trading_date "$(date +%Y-%m-%d)" \
    --argjson data "$data" \
    '{meta:{source:$source,endpoint:$endpoint,fetched_at:$fetched_at,symbol:(if ($symbol|length)>0 then $symbol else null end),trading_date:$trading_date},data:$data}'
}

# pw:: 前缀给 dispatcher（复用 em::* 实现）
pw::caps() {
  echo "quote kline index_quote sector_rank sector_constituents sector_kline limit_up_pool limit_down_pool north_flow dragon_tiger financials"
}

pw::quote()                { em::quote "$@"; }
pw::kline()                { em::kline "$@"; }
pw::index_quote()          { em::index_quote "$@"; }
pw::sector_rank()          { em::sector_rank "$@"; }
pw::sector_constituents()  { em::sector_constituents "$@"; }
pw::sector_kline()         { em::sector_kline "$@"; }
pw::limit_up_pool()        { em::limit_up_pool "$@"; }
pw::limit_down_pool()      { em::limit_down_pool "$@"; }
pw::north_flow()           { em::north_flow "$@"; }
pw::dragon_tiger()         { em::dragon_tiger "$@"; }
pw::financials()           { em::financials "$@"; }
pw::individual_info()      { em::individual_info "$@"; }
pw::announcements() { echo "playwright: announcements not implemented (use cninfo)" >&2; return 1; }
