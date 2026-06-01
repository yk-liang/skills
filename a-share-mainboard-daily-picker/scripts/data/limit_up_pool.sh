#!/usr/bin/env bash
# 涨停板池：./limit_up_pool.sh [date=YYYYMMDD]
# 默认查今日；返回含连板高度、首次/最后封板时间、封板资金、行业归类
# 仅 eastmoney 支持（A 股专属信号）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call limit_up_pool "${1:-}"
