#!/usr/bin/env bash
# Dispatcher — 顶层脚本统一加载 adapter 并支持 fallback chain
#
# 选源逻辑：
# 1. 若 SOURCE 环境变量被设置 → 强制单源（用于诊断 / 测试）
# 2. 否则按下方 chain 表 fallback，依次尝试，第一个成功的胜出
#
# macOS 默认 bash 3.2 不支持 declare -A，因此用 case 语句而非关联数组。

set -euo pipefail

# Endpoint → 优先级链。前面的优先用。
# A 股专属信号没有 itick fallback（itick 不支持），最后才走 browser。
# A 股公告优先 cninfo，eastmoney 没实现公告。
dispatch::_chain_for() {
  case "$1" in
    quote|kline|index_quote|stock_symbols) echo "eastmoney itick" ;;
    financials)                            echo "eastmoney" ;;
    announcements)                         echo "cninfo" ;;
    sector_rank|sector_constituents|sector_kline) echo "eastmoney" ;;
    limit_up_pool|limit_down_pool)         echo "eastmoney" ;;
    north_flow|dragon_tiger)               echo "eastmoney" ;;
    *)                                     echo "eastmoney" ;;
  esac
}

# adapter 名 → 函数前缀
dispatch::_prefix_for() {
  case "$1" in
    eastmoney) echo "em" ;;
    cninfo)    echo "cn" ;;
    itick)     echo "itick" ;;
    finnhub)   echo "fh" ;;
    *)         echo "" ;;
  esac
}

dispatch::_load_adapter() {
  local source_name="$1"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local adapter_file="${script_dir}/${source_name}.sh"
  if [ ! -f "$adapter_file" ]; then
    echo "dispatch: adapter not found: $adapter_file" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$adapter_file"
}

dispatch::_call_adapter() {
  local source_name="$1"; shift
  local endpoint="$1"; shift
  local prefix
  prefix=$(dispatch::_prefix_for "$source_name")
  if [ -z "$prefix" ]; then
    echo "dispatch: unknown adapter: $source_name" >&2
    return 1
  fi
  local fn="${prefix}::${endpoint}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    return 1   # adapter 没实现这个 endpoint，让上层换下一个
  fi
  "$fn" "$@"
}

dispatch::call() {
  # $1 endpoint name
  # rest 传给 adapter
  local endpoint="$1"; shift

  # 强制单源模式（SOURCE 环境变量优先）
  if [ -n "${SOURCE:-}" ]; then
    dispatch::_load_adapter "$SOURCE" || return 1
    dispatch::_call_adapter "$SOURCE" "$endpoint" "$@"
    return $?
  fi

  # Fallback chain 模式
  local chain
  chain=$(dispatch::_chain_for "$endpoint")
  local first_src
  first_src=$(echo "$chain" | awk '{print $1}')
  local last_err=""
  local attempted=0
  for src in $chain; do
    if ! dispatch::_load_adapter "$src" 2>/dev/null; then
      continue
    fi
    attempted=$((attempted + 1))
    local out
    local err_log
    err_log=$(mktemp)
    if out=$(dispatch::_call_adapter "$src" "$endpoint" "$@" 2>"$err_log"); then
      printf '%s' "$out"
      [ "$src" != "$first_src" ] && \
        echo "dispatch: fallback succeeded with $src for $endpoint (primary $first_src failed)" >&2
      rm -f "$err_log"
      return 0
    else
      last_err=$(cat "$err_log")
      rm -f "$err_log"
      [ -n "$last_err" ] && echo "$last_err" >&2
    fi
  done

  echo "dispatch: all sources in chain '$chain' failed for $endpoint (attempted $attempted)" >&2
  return 1
}

# 兼容旧接口（已废弃，但保留以免顶层脚本用到）
dispatch::load() {
  local source_name="${SOURCE:-eastmoney}"
  dispatch::_load_adapter "$source_name"
  echo "$source_name"
}
