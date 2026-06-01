#!/usr/bin/env bash
# 跌停板池：./limit_down_pool.sh [date=YYYYMMDD]
# 仅 eastmoney 支持
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call limit_down_pool "${1:-}"
