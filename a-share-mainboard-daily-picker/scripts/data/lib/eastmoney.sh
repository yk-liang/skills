#!/usr/bin/env bash
# 东方财富 adapter — A 股主力数据源
#
# 字段编码参考：
#   f2  现价        f3  涨跌幅(%)×100   f5  成交量(手)
#   f6  成交额(元)  f12 代码           f14 名称
#   f43 现价×100    f44 最高×100        f45 最低×100
#   f46 开盘×100    f47 成交量(手)      f48 成交额(元)
#   f57 代码        f58 名称           f60 昨收×100
#   f168 换手率(%)×100×100  f169 涨跌×100  f170 涨跌幅(%)×100
#   f104 上涨家数  f105 下跌家数
#
# 价格统一在 adapter 层面 ÷100 还原成元；adapter 对外暴露人类单位。

set -euo pipefail

EM_UA="${EM_UA:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36}"

# ---------- 工具函数 ----------

em::_now_ms() { echo "$(date +%s)000"; }

em::_iso_now() {
  if date -u +%Y-%m-%dT%H:%M:%S%z >/dev/null 2>&1; then
    date "+%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'
  else
    date -Iseconds
  fi
}

em::_get() {
  # GET with multi-host fallback for push2.eastmoney.com endpoints
  # 东财 push2 集群有多个数字前缀镜像（1.push2 ... 99.push2）；原始 push2 偶尔反爬空回应
  # 策略：每个 host 只 1 次 5s timeout（最差 4 hosts * 5s = 20s 总感知）
  #       而非旧版 2 retry × 15s = 最差 120s — 风控时让 dispatcher 尽快走 fallback
  local url="$1"
  local resp
  local hosts=("push2.eastmoney.com" "88.push2.eastmoney.com" "29.push2.eastmoney.com" "63.push2.eastmoney.com")
  local hosts_his=("push2his.eastmoney.com" "31.push2his.eastmoney.com" "60.push2his.eastmoney.com")

  # 选 host 池
  local pool
  if [[ "$url" == *"push2his.eastmoney.com"* ]]; then
    pool=("${hosts_his[@]}")
  elif [[ "$url" == *"push2.eastmoney.com"* ]]; then
    pool=("${hosts[@]}")
  else
    pool=("__nohost__")  # 非 push2 endpoint，不切 host
  fi

  for host in "${pool[@]}"; do
    local target_url="$url"
    if [ "$host" != "__nohost__" ]; then
      target_url=$(printf '%s' "$url" | sed -E "s|https://[0-9]*\.?push2(his)?\.eastmoney\.com|https://${host}|")
    fi
    if resp=$(curl -fsSL --max-time 5 -H "User-Agent: $EM_UA" -H "Referer: https://quote.eastmoney.com/" "$target_url" 2>/dev/null); then
      if [ -n "$resp" ]; then
        printf '%s' "$resp"
        return 0
      fi
    fi
  done
  echo "eastmoney: GET failed across all hosts: $url" >&2
  return 1
}

em::secid() {
  # 600519 → 1.600519（上交所）
  # 000001 → 0.000001（深交所）
  # 大致规则：6 开头 = 1.SH；0/3 开头 = 0.SZ；8/4/9 = 0.BJ；指数另外处理
  local code="$1"
  case "$code" in
    sh|SH|sh000001|上证) echo "1.000001"; return ;;
    sz|SZ|sz399001|深证) echo "0.399001"; return ;;
    cyb|CYB|创业板) echo "0.399006"; return ;;
    sh000300|沪深300) echo "1.000300"; return ;;
    BK*) echo "90.$code"; return ;;
  esac
  case "$code" in
    6*) echo "1.$code" ;;
    0*|3*) echo "0.$code" ;;
    8*|4*|9*) echo "0.$code" ;;
    *) echo "eastmoney: unknown code prefix: $code" >&2; return 1 ;;
  esac
}

em::is_mainboard() {
  # 主板代码：600/601/603/605（沪）+ 000/001/002/003（深）
  local code="$1"
  case "$code" in
    600*|601*|603*|605*|000*|001*|002*|003*) return 0 ;;
    *) return 1 ;;
  esac
}

em::wrap_meta() {
  # $1 endpoint, $2 symbol(可空), $3 data(JSON 字符串)
  local endpoint="$1"
  local symbol="${2:-}"
  local data="$3"
  jq -n \
    --arg source "eastmoney" \
    --arg endpoint "$endpoint" \
    --arg fetched_at "$(em::_iso_now)" \
    --arg symbol "$symbol" \
    --arg trading_date "$(date +%Y-%m-%d)" \
    --argjson data "$data" \
    '{meta:{source:$source,endpoint:$endpoint,fetched_at:$fetched_at,symbol:(if ($symbol|length)>0 then $symbol else null end),trading_date:$trading_date},data:$data}'
}

em::caps() {
  echo "quote kline index_quote sector_rank sector_constituents sector_kline limit_up_pool limit_down_pool north_flow dragon_tiger announcements financials individual_info"
}

# ---------- 业务函数 ----------

em::quote() {
  local code="$1"
  local secid; secid=$(em::secid "$code")
  local fields="f43,f44,f45,f46,f47,f48,f57,f58,f60,f168,f169,f170"
  local url="https://push2.eastmoney.com/api/qt/stock/get?secid=${secid}&fields=${fields}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    .data | {
      symbol: .f57,
      name: .f58,
      price: (.f43 / 100),
      open: (.f46 / 100),
      high: (.f44 / 100),
      low: (.f45 / 100),
      prev_close: (.f60 / 100),
      change: (.f169 / 100),
      change_pct: (.f170 / 100),
      volume_lots: .f47,
      turnover_yuan: .f48,
      turnover_rate_pct: (.f168 / 100)
    }')
  em::wrap_meta "quote" "$code" "$data"
}

em::kline() {
  local code="$1"
  local days="${2:-60}"
  local period="${3:-1d}"
  local secid; secid=$(em::secid "$code")
  local klt
  case "$period" in
    1d|day|D|d) klt=101 ;;
    1w|week|W|w) klt=102 ;;
    1mo|month|M) klt=103 ;;
    5m) klt=5 ;;
    15m) klt=15 ;;
    30m) klt=30 ;;
    60m|1h) klt=60 ;;
    *) klt=101 ;;
  esac
  # fqt=1 前复权
  local url="https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=${secid}&fields1=f1,f2,f3&fields2=f51,f52,f53,f54,f55,f56,f57,f58&klt=${klt}&fqt=1&end=20500101&lmt=${days}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    .data | {
      symbol: .code,
      name: .name,
      period: ("'"$period"'"),
      bars: (.klines | map(
        split(",") | {
          date: .[0],
          open: (.[1] | tonumber),
          close: (.[2] | tonumber),
          high: (.[3] | tonumber),
          low: (.[4] | tonumber),
          volume_lots: (.[5] | tonumber),
          turnover_yuan: (.[6] | tonumber),
          amplitude_pct: (.[7] | tonumber)
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
  em::wrap_meta "kline" "$code" "$data"
}

em::index_quote() {
  local idx="$1"
  local secid; secid=$(em::secid "$idx")
  local fields="f43,f44,f45,f46,f47,f48,f57,f58,f60,f168,f169,f170"
  local url="https://push2.eastmoney.com/api/qt/stock/get?secid=${secid}&fields=${fields}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    .data | {
      symbol: .f57,
      name: .f58,
      value: (.f43 / 100),
      open: (.f46 / 100),
      high: (.f44 / 100),
      low: (.f45 / 100),
      prev_close: (.f60 / 100),
      change: (.f169 / 100),
      change_pct: (.f170 / 100),
      volume_lots: .f47,
      turnover_yuan: .f48
    }')
  em::wrap_meta "index_quote" "$idx" "$data"
}

em::sector_rank() {
  # type: concept / industry
  local type="${1:-concept}"
  local fs
  case "$type" in
    concept|gn|概念) fs="m:90+t:3" ;;
    industry|hy|行业) fs="m:90+t:2" ;;
    *) echo "eastmoney: unknown sector type: $type" >&2; return 1 ;;
  esac
  # f3 板块涨幅 / f4 板块成交额(亿) / f8 换手率 / f12 板块代码 / f14 名称
  # f104 上涨家数 / f105 下跌家数 / f128 领涨股名 / f140 领涨股代码 / f136 领涨股涨幅
  local fields="f12,f14,f3,f4,f8,f104,f105,f128,f136,f140"
  local url="https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=50&po=1&np=1&fltt=2&invt=2&fid=f3&fs=${fs}&fields=${fields}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    {
      type: ("'"$type"'"),
      total: .data.total,
      sectors: (.data.diff | map({
        board_code: .f12,
        board_name: .f14,
        change_pct: .f3,
        turnover_pct: .f8,
        turnover_yi: .f4,
        up_count: .f104,
        down_count: .f105,
        leader_name: .f128,
        leader_code: .f140,
        leader_change_pct: .f136,
        breadth_pct: (
          if (.f104 + .f105) > 0 then
            ((.f104 / (.f104 + .f105)) * 10000 | round / 100)
          else null end
        )
      }))
    }')
  em::wrap_meta "sector_rank" "" "$data"
}

em::sector_constituents() {
  local board="$1"
  # f12 代码 / f14 名称 / f3 涨幅 / f5 成交量 / f6 成交额 / f8 换手率
  local fields="f12,f14,f2,f3,f5,f6,f8"
  local url="https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=200&po=1&np=1&fltt=2&invt=2&fid=f3&fs=b:${board}&fields=${fields}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    {
      board_code: ("'"$board"'"),
      total: .data.total,
      stocks: (.data.diff | map({
        code: .f12,
        name: .f14,
        price: .f2,
        change_pct: .f3,
        volume_lots: .f5,
        turnover_yuan: .f6,
        turnover_rate_pct: .f8
      }))
    }')
  em::wrap_meta "sector_constituents" "$board" "$data"
}

em::sector_kline() {
  local board="$1"
  local days="${2:-30}"
  local secid="90.${board}"
  local url="https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=${secid}&fields1=f1,f2,f3&fields2=f51,f52,f53,f54,f55,f56,f57,f58&klt=101&fqt=1&end=20500101&lmt=${days}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    .data | {
      board_code: .code,
      board_name: .name,
      bars: (.klines | map(
        split(",") | {
          date: .[0],
          open: (.[1] | tonumber),
          close: (.[2] | tonumber),
          high: (.[3] | tonumber),
          low: (.[4] | tonumber),
          volume_lots: (.[5] | tonumber),
          turnover_yuan: (.[6] | tonumber),
          amplitude_pct: (.[7] | tonumber)
        }
      ))
    } | . + {
      consecutive_up_days: (
        [.bars | reverse | .[] | .close > .open] | (
          if (.[0] // false) then
            (map(if . then 1 else 0 end) | until(. | (length == 0 or .[0] == 0); .[1:]) | length)
          else 0 end
        )
      )
    }')
  em::wrap_meta "sector_kline" "$board" "$data"
}

em::limit_up_pool() {
  local date="${1:-$(date +%Y%m%d)}"
  local url="https://push2ex.eastmoney.com/getTopicZTPool?ut=7eea3edcaed734bea9cbfc24409ed989&dpt=wz.ztzt&Pageindex=0&pagesize=300&sort=fbt%3Aasc&date=${date}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  # 字段含义（必读 — 之前 agent 把 ladder_count 误读为连板数导致严重判断错误）：
  #   consecutive_limit_up = lbc = 当前**真连板**天数（首板=1, 二连=2, ...）  ← 用这个
  #   today_intraday_breaks = zbc = 今日盘中涨停被打开的次数（不影响连板天数）
  #   limit_window_days = zttj.days = 近 N 个交易日的窗口跨度
  #   limits_in_window = zttj.ct = 该窗口内涨停过几次（不一定连续！）
  # 反面教材：利仁 001259（2026-06-03）lbc=1 是首板，但 ladder_days=18 ladder_count=9
  # 老版本字段命名让 agent 误读为"9 板"，结果是 18 天里涨停 9 次（断断续续），当前是首板换手板
  local data; data=$(printf '%s' "$resp" | jq '
    .data | {
      query_date: (.qdate | tostring),
      total: .tc,
      stocks: (.pool | map({
        code: .c,
        name: .n,
        price: (.p / 1000),
        change_pct: .zdp,
        turnover_yuan: .amount,
        circulating_mcap_yuan: .ltsz,
        total_mcap_yuan: .tshare,
        turnover_rate_pct: .hs,
        consecutive_limit_up: .lbc,
        first_limit_time: .fbt,
        last_limit_time: .lbt,
        limit_funds_yuan: .fund,
        today_intraday_breaks: .zbc,
        industry: .hybk,
        limit_window_days: (.zttj.days // null),
        limits_in_window: (.zttj.ct // null)
      } | . + {
        is_first_board: (.consecutive_limit_up == 1),
        is_pure_streak: ((.limits_in_window // 0) == .consecutive_limit_up),
        ladder_label: (
          if .consecutive_limit_up == 1 then "首板"
          elif .consecutive_limit_up == 2 then "2连板"
          elif .consecutive_limit_up == 3 then "3连板"
          elif .consecutive_limit_up >= 4 then "\(.consecutive_limit_up)连板"
          else "未知"
          end
        ),
        window_summary: (
          if (.limits_in_window // 0) > .consecutive_limit_up and (.limit_window_days // 0) > 0 then
            "\(.limit_window_days)天\(.limits_in_window)板（含断板）"
          else null
          end
        )
      }))
    } | . + {
      mainboard_count: ([.stocks[] | select(
        (.code | startswith("600") or startswith("601") or startswith("603") or startswith("605") or startswith("000") or startswith("001") or startswith("002") or startswith("003"))
      )] | length),
      max_consecutive: ([.stocks[].consecutive_limit_up] | max // 0),
      pure_streak_3plus_count: ([.stocks[] | select(.consecutive_limit_up >= 3)] | length)
    }')
  em::wrap_meta "limit_up_pool" "" "$data"
}

em::limit_down_pool() {
  local date="${1:-$(date +%Y%m%d)}"
  local url="https://push2ex.eastmoney.com/getTopicDTPool?ut=7eea3edcaed734bea9cbfc24409ed989&dpt=wz.dtzt&Pageindex=0&pagesize=300&sort=fund%3Aasc&date=${date}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    .data | {
      query_date: (.qdate | tostring),
      total: (.tc // 0),
      stocks: ((.pool // []) | map({
        code: .c,
        name: .n,
        price: (.p / 1000),
        change_pct: .zdp,
        turnover_yuan: .amount,
        industry: .hybk,
        last_limit_time: .lbt
      }))
    }')
  em::wrap_meta "limit_down_pool" "" "$data"
}

em::north_flow() {
  local url="https://push2.eastmoney.com/api/qt/kamt/get?fields1=f1,f2,f3,f4&fields2=f51,f52,f54,f55,f56&ut=b2884a393a59ad64002292a3e90d46a5&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    .data | {
      hk_to_sh_net_yuan: .hk2sh.dayNetAmtIn,
      hk_to_sz_net_yuan: .hk2sz.dayNetAmtIn,
      sh_to_hk_net_yuan: .sh2hk.dayNetAmtIn,
      sz_to_hk_net_yuan: .sz2hk.dayNetAmtIn,
      hk_to_sh_status: .hk2sh.status,
      hk_to_sz_status: .hk2sz.status,
      date: .hk2sh.date2,
      total_north_in_yuan: ((.hk2sh.dayNetAmtIn + .hk2sz.dayNetAmtIn) | round)
    }')
  em::wrap_meta "north_flow" "" "$data"
}

em::dragon_tiger() {
  local date="${1:-$(date +%Y-%m-%d)}"
  local url="https://datacenter-web.eastmoney.com/api/data/v1/get?sortColumns=NET_BUY_AMT&sortTypes=-1&pageSize=200&pageNumber=1&reportName=RPT_DAILYBILLBOARD_DETAILS&columns=ALL&filter=(TRADE_DATE%3D%27${date}%27)&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq '
    {
      query_date: ("'"$date"'"),
      total: (.result.count // 0),
      stocks: ((.result.data // []) | map({
        code: .SECURITY_CODE,
        name: .SECURITY_NAME_ABBR,
        change_pct: .CHANGE_RATE,
        net_buy_yuan: .NET_BUY_AMT,
        buy_yuan: .BUY_AMT,
        sell_yuan: .SELL_AMT,
        turnover_yuan: .TURNOVERRATE,
        reason: .EXPLANATION,
        type: .EXPLAIN_TYPE
      }))
    }')
  em::wrap_meta "dragon_tiger" "" "$data"
}

em::announcements() {
  # 占位 — 巨潮接口在 cninfo.sh 实现
  echo "eastmoney: announcements not implemented; use SOURCE=cninfo" >&2
  return 1
}

em::individual_info() {
  # 个股基础信息：通过 push2 stock/get 扩展字段拿
  # 实测字段（茅台 2026-06）：
  #   f57=代码 f58=名称 f43=现价×100 f116=流通市值(元) f117=总市值(元)
  #   f84=总股本 f85=流通股 f127=二级行业(字符串如"白酒Ⅱ")
  # listing_date 字段未在 push2 stock/get 暴露 → 留 null，akshare 主源已有
  local code="$1"
  local secid; secid=$(em::secid "$code")
  local fields="f57,f58,f43,f116,f117,f84,f85,f127"
  local url="https://push2.eastmoney.com/api/qt/stock/get?secid=${secid}&fields=${fields}&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  local data; data=$(printf '%s' "$resp" | jq --arg code "$code" '
    .data | {
      symbol: $code,
      name: .f58,
      latest_price: (if .f43 then .f43 / 100 else null end),
      industry: .f127,
      listing_date: null,
      total_shares: .f84,
      floating_shares: .f85,
      total_mcap_yuan: .f117,
      floating_mcap_yuan: .f116
    }')
  em::wrap_meta "individual_info" "$code" "$data"
}

em::financials() {
  local code="$1"
  # 仅保留东财已校验存在的字段，免得一个字段错让全局 9501
  local cols="REPORT_DATE,EPSJB,EPSKCJB,MGJYXJJE,TOTALOPERATEREVE,PARENTNETPROFIT,KCFJCXSYJLR,TOTALOPERATEREVETZ,PARENTNETPROFITTZ,KCFJCXSYJLRTZ,ROEJQ,ROEKCJQ,XSMLL,XSJLL,ZCFZL"
  local url="https://datacenter.eastmoney.com/securities/api/data/v1/get?reportName=RPT_F10_FINANCE_MAINFINADATA&columns=${cols}&filter=(SECURITY_CODE%3D%22${code}%22)&pageNumber=1&pageSize=8&sortTypes=-1&sortColumns=REPORT_DATE&source=HSF10&client=PC&_=$(em::_now_ms)"
  local resp; resp=$(em::_get "$url") || return 1

  # 检查 success 标志，9501 等错误时 result 为 null
  local ok; ok=$(printf '%s' "$resp" | jq -r '.success // false')
  if [ "$ok" != "true" ]; then
    local errmsg; errmsg=$(printf '%s' "$resp" | jq -r '.message // "unknown"')
    echo "eastmoney: financials API error: $errmsg" >&2
    return 1
  fi

  local data; data=$(printf '%s' "$resp" | jq --arg code "$code" '
    {
      symbol: $code,
      reports: ((.result.data // []) | map({
        report_date: (.REPORT_DATE | split(" ")[0]),
        revenue_yuan: .TOTALOPERATEREVE,
        revenue_yoy_pct: .TOTALOPERATEREVETZ,
        net_profit_yuan: .PARENTNETPROFIT,
        net_profit_yoy_pct: .PARENTNETPROFITTZ,
        deducted_net_profit_yuan: .KCFJCXSYJLR,
        deducted_net_profit_yoy_pct: .KCFJCXSYJLRTZ,
        operating_cashflow_per_share: .MGJYXJJE,
        gross_margin_pct: .XSMLL,
        net_margin_pct: .XSJLL,
        roe_pct: .ROEJQ,
        roe_deducted_pct: .ROEKCJQ,
        eps_yuan: .EPSJB,
        eps_deducted_yuan: .EPSKCJB,
        debt_ratio_pct: .ZCFZL
      }))
    }')
  em::wrap_meta "financials" "$code" "$data"
}
