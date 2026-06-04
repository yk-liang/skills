#!/usr/bin/env bash
# 炸板池：./broken_up_pool.sh [date=YYYYMMDD]
# 今日触及涨停后被打开的股票（市场情绪关键指标 — 同花顺 app 显示的"涨停打开"）
# 健康市场炸板少；炸板多 = 接力意愿弱 = 退潮预警
# 仅 akshare 实现
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call broken_up_pool "${1:-}"
