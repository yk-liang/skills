#!/usr/bin/env bash
# 北向资金历史每日数据 + 5/20/30 日累计：./north_flow_history.sh [days=30]
# 仅 akshare 实现（用 ak.stock_hsgt_hist_em）
# 用途：判断外资中长期方向（当日 north_flow 只能看单点）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call north_flow_history "${1:-30}"
