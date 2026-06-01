#!/usr/bin/env bash
# 板块涨幅榜：./sector_rank.sh [type=concept]
# type: concept (概念板块) / industry (行业板块)
# 仅 eastmoney 支持
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call sector_rank "${1:-concept}"
