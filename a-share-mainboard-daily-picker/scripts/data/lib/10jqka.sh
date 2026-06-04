#!/usr/bin/env bash
# 同花顺 adapter — 当东财 push2 被风控时的二级数据源
#
# A 股能力（已实测）：
#   - quote / kline / index_quote
#   - limit_up_pool（同花顺有自己的，含中文 high_days "首板/2连板"标签，可作交叉验证）
#
# 不实现的（让 dispatcher fall through）：
#   sector_rank / sector_constituents / sector_kline / north_flow / dragon_tiger
#   announcements / financials  ← 这些走东财/巨潮
#
# 同花顺接口特点：
#   - JSONP 包装（quotebridge_xxx(...) 需用 sed 剥离）
#   - 字段是数字 key 编码（"10"=现价 "7"=开盘 "8"=高 "9"=低 "6"=昨收 ...）
#   - 无 cookie 反爬（实测干净 curl 通）
#   - 指数：1A0001=上证、399001=深成、399006=创业板、000300=沪深300
#   - 注意：限速比东财严，单脚本调用控制在每分钟 20 次以内

set -euo pipefail

THS_UA="${THS_UA:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36}"

ths::_iso_now() {
  if date "+%Y-%m-%dT%H:%M:%S%z" >/dev/null 2>&1; then
    date "+%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'
  else
    date -Iseconds
  fi
}

ths::_get() {
  # GET with retry. 同花顺有 JSONP 包装，调用方负责剥离
  local url="$1"
  local referer="${2:-http://stockpage.10jqka.com.cn/}"
  local tries=0
  local resp
  while [ $tries -lt 2 ]; do
    if resp=$(curl -fsSL --max-time 15 -H "User-Agent: $THS_UA" -H "Referer: $referer" "$url" 2>/dev/null); then
      if [ -n "$resp" ]; then
        printf '%s' "$resp"
        return 0
      fi
    fi
    tries=$((tries + 1))
    sleep 1
  done
  echo "10jqka: GET failed after retry: $url" >&2
  return 1
}

ths::_strip_jsonp() {
  # quotebridge_v6_realhead_hs_600519_last({...}) → {...}
  sed -E 's/^[a-zA-Z_0-9]+\((.*)\)$/\1/'
}

ths::wrap_meta() {
  local endpoint="$1"
  local symbol="${2:-}"
  local data="$3"
  jq -n \
    --arg source "10jqka" \
    --arg endpoint "$endpoint" \
    --arg fetched_at "$(ths::_iso_now)" \
    --arg symbol "$symbol" \
    --arg trading_date "$(date +%Y-%m-%d)" \
    --argjson data "$data" \
    '{meta:{source:$source,endpoint:$endpoint,fetched_at:$fetched_at,symbol:(if ($symbol|length)>0 then $symbol else null end),trading_date:$trading_date},data:$data}'
}

ths::caps() {
  echo "quote kline index_quote limit_up_pool"
}

# 同花顺代码前缀：A 股都是 hs_<code>；指数也是 hs_<code>
# 主板 sh: 600/601/603/605/688/689 用 hs_；sz: 000/001/002/003/300/301 用 hs_
# 区分上交所/深交所不需要，同花顺统一 hs_
ths::_ths_code() {
  case "$1" in
    sh|SH|上证) echo "1A0001" ;;
    sz|SZ|深证) echo "399001" ;;
    cyb|CYB|创业板) echo "399006" ;;
    sh000300|沪深300) echo "000300" ;;
    *) echo "$1" ;;
  esac
}

ths::quote() {
  local code="$1"
  local ths_code; ths_code=$(ths::_ths_code "$code")
  local url="http://d.10jqka.com.cn/v6/realhead/hs_${ths_code}/last.js"
  local resp; resp=$(ths::_get "$url") || return 1
  local clean; clean=$(printf '%s' "$resp" | ths::_strip_jsonp)

  # 同花顺 quote 字段映射（已实测）：
  #   "5"=代码 "6"=昨收 "7"=开盘 "8"=最高 "9"=最低 "10"=现价
  #   "13"=成交量(手) "19"=成交额(元) "1968584"=换手率(%)
  #   "199112"=涨幅(%) "264648"=涨跌(元) "2942"=PE
  local data; data=$(printf '%s' "$clean" | jq --arg code "$code" '
    .items | {
      symbol: $code,
      name: null,
      price: (.["10"] | tonumber? // null),
      open: (.["7"] | tonumber? // null),
      high: (.["8"] | tonumber? // null),
      low: (.["9"] | tonumber? // null),
      prev_close: (.["6"] | tonumber? // null),
      change: (.["264648"] | tonumber? // null),
      change_pct: (.["199112"] | tonumber? // null),
      volume_lots: (.["13"] | tonumber? // null),
      turnover_yuan: (.["19"] | tonumber? // null),
      turnover_rate_pct: (.["1968584"] | tonumber? // null),
      pe: (.["2942"] | tonumber? // null)
    } | . + {
      change: (if .change == null and .price != null and .prev_close != null then
                  ((.price - .prev_close) * 100 | round / 100)
                else .change end),
      change_pct: (if .change_pct == null and .price != null and .prev_close != null and .prev_close != 0 then
                      ((.price - .prev_close) / .prev_close * 10000 | round / 100)
                    else .change_pct end)
    }')
  ths::wrap_meta "quote" "$code" "$data"
}

ths::kline() {
  local code="$1"
  local days="${2:-60}"
  local period="${3:-1d}"
  local ths_code; ths_code=$(ths::_ths_code "$code")
  # period → 同花顺路径段
  local seg
  case "$period" in
    1d|day|D|d) seg="01" ;;
    1w|week|W|w) seg="11" ;;
    1mo|month|M) seg="21" ;;
    5m) seg="05" ;;
    15m) seg="15" ;;
    30m) seg="30" ;;
    60m|1h) seg="60" ;;
    *) seg="01" ;;
  esac
  local url="http://d.10jqka.com.cn/v4/line/hs_${ths_code}/${seg}/last${days}.js"
  local resp; resp=$(ths::_get "$url") || return 1
  local clean; clean=$(printf '%s' "$resp" | ths::_strip_jsonp)

  # K 线 data 字段顺序（已实测）：date,open,high,low,close,vol(手),amount(元),turnover_rate(%),_,_,_
  local data; data=$(printf '%s' "$clean" | jq --arg code "$code" --arg period "$period" '
    {
      symbol: $code,
      name: (.name // null),
      period: $period,
      bars: (((.data // "") | split(";")) | map(
        split(",") | select(length >= 5) | {
          date: (.[0] | (.[:4] + "-" + .[4:6] + "-" + .[6:8])),
          open: (.[1] | tonumber? // null),
          high: (.[2] | tonumber? // null),
          low: (.[3] | tonumber? // null),
          close: (.[4] | tonumber? // null),
          volume_lots: (.[5] | tonumber? // null),
          turnover_yuan: (.[6] | tonumber? // null),
          turnover_rate_pct: (if length > 7 then (.[7] | tonumber? // null) else null end)
        }
      ))
    } | . + {
      ma5: (
        if (.bars | length) >= 5 then
          (.bars[-5:] | map(.close) | add / 5 | . * 100 | round / 100)
        else null end
      ),
      ma10: (
        if (.bars | length) >= 10 then
          (.bars[-10:] | map(.close) | add / 10 | . * 100 | round / 100)
        else null end
      ),
      ma20: (
        if (.bars | length) >= 20 then
          (.bars[-20:] | map(.close) | add / 20 | . * 100 | round / 100)
        else null end
      ),
      ma60: (
        if (.bars | length) >= 60 then
          (.bars[-60:] | map(.close) | add / 60 | . * 100 | round / 100)
        else null end
      ),
      change_5d_pct: (
        if (.bars | length) >= 6 then
          (((.bars[-1].close - .bars[-6].close) / .bars[-6].close) * 10000 | round / 100)
        else null end
      ),
      change_20d_pct: (
        if (.bars | length) >= 21 then
          (((.bars[-1].close - .bars[-21].close) / .bars[-21].close) * 10000 | round / 100)
        else null end
      ),
      change_60d_pct: (
        if (.bars | length) >= 61 then
          (((.bars[-1].close - .bars[-61].close) / .bars[-61].close) * 10000 | round / 100)
        else null end
      ),
      avg_volume_5d_lots: (
        if (.bars | length) >= 5 then
          (.bars[-5:] | map(.volume_lots) | add / 5 | round)
        else null end
      ),
      avg_volume_20d_lots: (
        if (.bars | length) >= 20 then
          (.bars[-20:] | map(.volume_lots) | add / 20 | round)
        else null end
      )
    }')
  ths::wrap_meta "kline" "$code" "$data"
}

ths::index_quote() {
  # 复用 quote 逻辑，把指数当 stock 处理
  local idx="$1"
  local ths_code; ths_code=$(ths::_ths_code "$idx")
  local url="http://d.10jqka.com.cn/v6/realhead/hs_${ths_code}/last.js"
  local resp; resp=$(ths::_get "$url") || return 1
  local clean; clean=$(printf '%s' "$resp" | ths::_strip_jsonp)
  local data; data=$(printf '%s' "$clean" | jq --arg sym "$ths_code" '
    .items | {
      symbol: $sym,
      name: null,
      value: (.["10"] | tonumber? // null),
      open: (.["7"] | tonumber? // null),
      high: (.["8"] | tonumber? // null),
      low: (.["9"] | tonumber? // null),
      prev_close: (.["6"] | tonumber? // null),
      change: (.["264648"] | tonumber? // null),
      change_pct: (.["199112"] | tonumber? // null),
      volume_lots: (.["13"] | tonumber? // null),
      turnover_yuan: (.["19"] | tonumber? // null)
    } | . + {
      change: (if .change == null and .value != null and .prev_close != null then
                  ((.value - .prev_close) * 100 | round / 100)
                else .change end),
      change_pct: (if .change_pct == null and .value != null and .prev_close != null and .prev_close != 0 then
                      ((.value - .prev_close) / .prev_close * 10000 | round / 100)
                    else .change_pct end)
    }')
  ths::wrap_meta "index_quote" "$idx" "$data"
}

ths::limit_up_pool() {
  # 同花顺涨停池有权威的 high_days 中文标签 "首板/2连板/3连板"
  # 也有 open_num（≈ 东财 zbc）、reason_type（涨停原因）、is_again_limit（断板反包标志）
  local date_param="${1:-$(date +%Y%m%d)}"
  # 同花顺 limit 上限 200（实测：limit=300 → status_code=-1 "limit must be less than or equal to 200"）
  local url="http://data.10jqka.com.cn/dataapi/limit_up/limit_up_pool?page=1&limit=200&field=199112,10,9001,330323,330324,330325,9002,330329,133971,9003,9004&filter=HS&order_field=199112&order_type=0&date=${date_param}"
  local resp; resp=$(ths::_get "$url" "http://q.10jqka.com.cn/zt/") || return 1
  local status_code; status_code=$(printf '%s' "$resp" | jq -r '.status_code // -1')
  if [ "$status_code" != "0" ]; then
    echo "10jqka: limit_up_pool error code=$status_code" >&2
    return 1
  fi
  local data; data=$(printf '%s' "$resp" | jq --arg qd "$date_param" '
    {
      query_date: $qd,
      total: (.data.page.total // 0),
      stocks: ((.data.info // []) | map({
        code: .code,
        name: .name,
        price: .latest,
        change_pct: .change_rate,
        ladder_label: .high_days,                  # 同花顺权威中文："首板/2连板/3连板"
        change_tag: .change_tag,                   # FIRST_LIMIT / LIMIT_BACK / AGAIN_LIMIT
        limit_up_type: .limit_up_type,             # "换手板" / "T 字板" / "一字板"
        today_intraday_breaks: .open_num,          # 今日盘中开板次数
        is_again_limit: (.is_again_limit == 1),    # 断板反包
        reason_type: .reason_type,                 # 涨停原因（"多芯光纤+CPO+一季报增长"）
        limit_up_suc_rate: .limit_up_suc_rate,     # 涨停成功率
        first_limit_up_ts: (.first_limit_up_time | tonumber? // null),
        last_limit_up_ts: (.last_limit_up_time | tonumber? // null),
        market_type: .market_type                  # HS / GEM / STAR
      } | . + {
        # 字段语义（必读 — 防止 agent 误读）：
        #   consecutive_limit_up = 真连板数（严格意义）。"首板"=1, "N连板"=N。
        #     "M天N板" 当 M==N 时 = 纯连板 N；M > N 时 = 含断板，返回 null
        #   streak_height = 市场认知的"高度"（炒作意义）。"首板"=1, "N连板"=N, "M天N板"=N
        #     这是题材热度指标，N 是窗口内涨停总次数（不必连续）
        #   is_pure_streak = 是否纯连板（无断板）
        #   反面教材：
        #     6/3 红星发展 ladder_label="7天5板" → consecutive_limit_up=null（含断板）, streak_height=5
        #     6/3 利仁     ladder_label="首板"   → consecutive_limit_up=1（agent 之前误读成 9）
        #     6/3 天洋新材  ladder_label="3天3板" → consecutive_limit_up=3（纯 3连板）
        consecutive_limit_up: (
          if .ladder_label == "首板" then 1
          elif (.ladder_label | test("^[0-9]+连板$")) then (.ladder_label | capture("(?<n>[0-9]+)") | .n | tonumber)
          elif (.ladder_label | test("^[0-9]+天[0-9]+板$")) then
            ((.ladder_label | capture("^(?<m>[0-9]+)天(?<n>[0-9]+)板$")) as $g |
             if ($g.m | tonumber) == ($g.n | tonumber) then ($g.n | tonumber)
             else null
             end)
          else null
          end
        ),
        streak_height: (
          if .ladder_label == "首板" then 1
          elif (.ladder_label | test("^[0-9]+连板$")) then (.ladder_label | capture("(?<n>[0-9]+)") | .n | tonumber)
          elif (.ladder_label | test("^[0-9]+天[0-9]+板$")) then (.ladder_label | capture("天(?<n>[0-9]+)板") | .n | tonumber)
          else null
          end
        ),
        is_first_board: (.ladder_label == "首板"),
        is_pure_streak: (
          if .ladder_label == "首板" then true
          elif (.ladder_label | test("^[0-9]+连板$")) then true
          elif (.ladder_label | test("^[0-9]+天[0-9]+板$")) then
            ((.ladder_label | capture("^(?<m>[0-9]+)天(?<n>[0-9]+)板$")) as $g |
             ($g.m | tonumber) == ($g.n | tonumber))
          else null
          end
        )
      }))
    } | . + {
      mainboard_count: ([.stocks[] | select(
        (.code | startswith("600") or startswith("601") or startswith("603") or startswith("605") or startswith("000") or startswith("001") or startswith("002") or startswith("003"))
      )] | length),
      max_pure_consecutive: ([.stocks[].consecutive_limit_up // 0] | max // 0),
      max_streak_height: ([.stocks[].streak_height // 0] | max // 0)
    }')
  ths::wrap_meta "limit_up_pool" "" "$data"
}

# 不实现的（让 dispatcher fall through）
ths::sector_rank()        { echo "10jqka: sector_rank not implemented" >&2; return 1; }
ths::sector_constituents() { echo "10jqka: sector_constituents not implemented" >&2; return 1; }
ths::sector_kline()       { echo "10jqka: sector_kline not implemented" >&2; return 1; }
ths::limit_down_pool()    { echo "10jqka: limit_down_pool not implemented" >&2; return 1; }
ths::north_flow()         { echo "10jqka: north_flow not implemented" >&2; return 1; }
ths::dragon_tiger()       { echo "10jqka: dragon_tiger not implemented" >&2; return 1; }
ths::announcements()      { echo "10jqka: announcements not implemented; use cninfo" >&2; return 1; }
ths::financials()         { echo "10jqka: financials not implemented; use eastmoney" >&2; return 1; }
