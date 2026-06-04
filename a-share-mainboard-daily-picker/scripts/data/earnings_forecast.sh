#!/usr/bin/env bash
# 业绩预告：./earnings_forecast.sh [date=YYYYMMDD]
# 默认查最近季度末（20260331）；含预测净利同比变动幅度
# 仅 akshare 实现
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call earnings_forecast "${1:-}"
