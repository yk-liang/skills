#!/usr/bin/env bash
# 板块 K 线（看板块持续性 + 缠论中枢识别）：./sector_kline.sh <board_code> [days=30]
# fallback chain：eastmoney → playwright
# 后处理：dispatch 输出 pipe 到 kline_enrich.py 加 MACD + 中枢 + 缠论买卖点
# 用途：板块阶段判定从主观词改为客观（突破中枢上沿 = 主升 / 跌破下沿 = 退潮）
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <board_code> [days=30]" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
source "$SCRIPT_DIR/lib/_python.sh"

RAW=$(dispatch::call sector_kline "$@") || exit $?

PY=$(skill_python 2>/dev/null || true)
if [ -n "$PY" ] && [ -f "$SCRIPT_DIR/lib/kline_enrich.py" ]; then
  printf '%s' "$RAW" | "$PY" "$SCRIPT_DIR/lib/kline_enrich.py"
else
  printf '%s\n' "$RAW"
fi
