#!/usr/bin/env bash
# AKShare adapter — Python helper wrapper
#
# 何时用：
# - K 线：东财 push2his 风控时 fallback
# - 龙虎榜 / 北向：东财 datacenter URL 经常空数据，akshare 用不同路径稳定拿
# - 财务三表完整版：比 eastmoney 主要指标多一倍字段
# - 业绩预告：新能力（巨潮要解析，akshare 直接给）
# - 个股基础信息：市值/行业/上市时间
#
# 不实现：
# - 板块榜 / 成分股：akshare 内部也是 push2 同样 URL，同样被风控（实测确认）
# - 单股 quote / index_quote：akshare 的 stock_zh_a_spot_em 是全量 5800 只大请求，反而更易触发风控
#
# 依赖：pip3 install akshare（已装则 import 即可）

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_python.sh"

ak::_iso_now() {
  if date "+%Y-%m-%dT%H:%M:%S%z" >/dev/null 2>&1; then
    date "+%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'
  else
    date -Iseconds
  fi
}

ak::_check_python() {
  local py; py=$(skill_python)
  if ! "$py" -c "import akshare" 2>/dev/null; then
    cat >&2 <<EOF
akshare: NOT AVAILABLE (python at: $py)
To enable this fallback (recommended for龙虎榜/北向/财务三表):
  Option 1 (recommended — isolated venv):
    cd $(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) && ./scripts/setup.sh
  Option 2 (manual, may pollute global env):
    pip3 install akshare
EOF
    return 1
  fi
}

ak::_run() {
  ak::_check_python || return 1
  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local py; py=$(skill_python)
  "$py" "$script_dir/akshare_helper.py" "$@"
}

ak::caps() {
  echo "kline dragon_tiger north_flow north_flow_history financials_full earnings_forecast individual_info limit_up_pool limit_down_pool broken_up_pool"
}

ak::kline()                { ak::_run kline "$@"; }
ak::dragon_tiger()         { ak::_run dragon_tiger "$@"; }
ak::north_flow()           { ak::_run north_flow "$@"; }
ak::north_flow_history()   { ak::_run north_flow_history "$@"; }
ak::financials_full()   { ak::_run financials_full "$@"; }
ak::earnings_forecast() { ak::_run earnings_forecast "$@"; }
ak::individual_info()   { ak::_run individual_info "$@"; }
ak::limit_up_pool()     { ak::_run limit_up_pool "$@"; }
ak::limit_down_pool()   { ak::_run limit_down_pool "$@"; }
ak::broken_up_pool()    { ak::_run broken_up_pool "$@"; }

# 不实现的（让 dispatcher fall through）
ak::quote()                { echo "akshare: quote not implemented (use eastmoney/10jqka)" >&2; return 1; }
ak::index_quote()          { echo "akshare: index_quote not implemented (use eastmoney/10jqka)" >&2; return 1; }
ak::sector_rank()          { echo "akshare: sector_rank uses same push2 path, also blocked; use playwright" >&2; return 1; }
ak::sector_constituents()  { echo "akshare: sector_constituents same as above" >&2; return 1; }
ak::sector_kline()         { echo "akshare: sector_kline not implemented" >&2; return 1; }
# limit_down_pool 已在上方实现（救东财 getTopicDTPool 假死 bug）
ak::announcements()        { echo "akshare: announcements not implemented; use cninfo" >&2; return 1; }
ak::financials()           { echo "akshare: financials → use financials_full or eastmoney" >&2; return 1; }
