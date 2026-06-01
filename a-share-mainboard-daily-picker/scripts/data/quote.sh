#!/usr/bin/env bash
# 实时行情：./quote.sh <code>
# 默认 fallback chain：eastmoney → itick；强制单源用 SOURCE=xxx
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <stock_code>" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call quote "$@"
