#!/usr/bin/env bash
# 财务核心字段：./financials.sh <code>
# 返回最近 8 期：营收/归母/扣非/同比/毛利率/净利率/ROE/经营现金流
# 仅 eastmoney 支持完整三表（itick 只有 PE/市值，能力不足故不在 chain 中）
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <stock_code>" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call financials "$@"
