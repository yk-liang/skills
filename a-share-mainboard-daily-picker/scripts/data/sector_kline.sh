#!/usr/bin/env bash
# 板块 K 线（看板块持续性）：./sector_kline.sh <board_code> [days=30]
# 仅 eastmoney 支持
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <board_code> [days=30]" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call sector_kline "$@"
