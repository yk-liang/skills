#!/usr/bin/env bash
# 指数行情：./index_quote.sh <index>
# index: sh (上证) / sz (深证) / cyb (创业板) / sh000300 (沪深300)
# 默认 fallback chain：eastmoney → itick
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <sh|sz|cyb|sh000300>" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call index_quote "$@"
