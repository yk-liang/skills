#!/usr/bin/env bash
# 板块 K 线 + 缠论中枢识别：./sector_kline.sh <board_code_or_name> [days=60]
# fallback chain：eastmoney → 10jqka（按板块名查询） → playwright
# 后处理：pipe 到 kline_enrich.py 加 MACD + 中枢 + 缠论买卖点
# 东财 IP 风控时 10jqka 独立可用（仅限同花顺有对应板块的情况，覆盖 ~70%）
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <board_code_or_name> [days=60]" >&2; exit 2; }
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
