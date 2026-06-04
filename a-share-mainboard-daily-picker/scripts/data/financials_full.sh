#!/usr/bin/env bash
# 完整三表（资产负债 / 利润 / 现金流）：./financials_full.sh <code>
# 比 financials.sh 多三表原始字段（资产、负债、所有者权益、营收、成本、净利、经营/投资/筹资现金流）
# 仅 akshare 实现
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <stock_code>" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call financials_full "$@"
