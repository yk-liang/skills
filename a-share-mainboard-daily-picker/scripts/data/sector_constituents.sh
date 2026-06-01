#!/usr/bin/env bash
# 板块成分股：./sector_constituents.sh <board_code>
# board_code 例：BK1013（华为欧拉），通过 sector_rank.sh 拿
# 仅 eastmoney 支持
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <board_code> (e.g. BK1013)" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call sector_constituents "$@"
