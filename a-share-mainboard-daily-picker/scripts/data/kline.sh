#!/usr/bin/env bash
# K 线 + 均线计算：./kline.sh <code> [days=60] [period=1d]
# period: 1d / 1w / 1mo / 5m / 15m / 30m / 60m
# 默认 fallback chain：eastmoney → itick
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <stock_code> [days=60] [period=1d]" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call kline "$@"
