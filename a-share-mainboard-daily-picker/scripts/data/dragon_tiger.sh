#!/usr/bin/env bash
# 龙虎榜：./dragon_tiger.sh [date=YYYY-MM-DD]
# 仅 eastmoney 支持
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call dragon_tiger "${1:-}"
