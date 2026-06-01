#!/usr/bin/env bash
# 公告（巨潮）：./announcements.sh <code> [days=30]
# 仅 cninfo 支持
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <stock_code> [days=30]" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/_dispatch.sh"
dispatch::call announcements "$@"
