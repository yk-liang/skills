#!/usr/bin/env bash
# K 线 + 均线 + MACD：./kline.sh <code> [days=60] [period=1d]
# period: 1d / 1w / 1mo / 5m / 15m / 30m / 60m
# 默认 fallback chain：eastmoney → 10jqka → akshare → itick → playwright
# 后处理：dispatch 输出 pipe 到 kline_enrich.py 加 MACD 字段（缠论 ② 背驰检测）
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <stock_code> [days=60] [period=1d]" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
source "$SCRIPT_DIR/lib/_python.sh"

RAW=$(dispatch::call kline "$@") || exit $?

PY=$(skill_python 2>/dev/null || true)
if [ -n "$PY" ] && [ -f "$SCRIPT_DIR/lib/kline_enrich.py" ]; then
  printf '%s' "$RAW" | "$PY" "$SCRIPT_DIR/lib/kline_enrich.py"
else
  printf '%s\n' "$RAW"
fi
