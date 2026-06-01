#!/usr/bin/env bash
# 北向资金当日净流入：./north_flow.sh
# 仅 eastmoney 支持（A 股专属信号）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call north_flow
