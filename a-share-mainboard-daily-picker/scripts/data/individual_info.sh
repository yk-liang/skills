#!/usr/bin/env bash
# 个股基础信息：./individual_info.sh <code>
# 含市值、行业、上市日期、总股本/流通股
# 仅 akshare 实现
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <stock_code>" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call individual_info "$@"
