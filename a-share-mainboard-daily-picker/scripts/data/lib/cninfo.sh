#!/usr/bin/env bash
# 巨潮资讯网 adapter — A 股公告原始数据
#
# 巨潮 stock 字段需要 "代码,orgId" 格式，orgId 通过 stock 检索接口拿到
# 简化方案：plate=sse/szse + stock=代码,代码 — 测试发现单纯 stock=代码,代码 也能查到
# 如果失败再走 SHOW_ANN_BY_CODE 兜底

set -euo pipefail

CN_UA="${CN_UA:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36}"

cn::_iso_now() {
  if date "+%Y-%m-%dT%H:%M:%S%z" >/dev/null 2>&1; then
    date "+%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'
  else
    date -Iseconds
  fi
}

cn::wrap_meta() {
  local endpoint="$1"
  local symbol="${2:-}"
  local data="$3"
  jq -n \
    --arg source "cninfo" \
    --arg endpoint "$endpoint" \
    --arg fetched_at "$(cn::_iso_now)" \
    --arg symbol "$symbol" \
    --arg trading_date "$(date +%Y-%m-%d)" \
    --argjson data "$data" \
    '{meta:{source:$source,endpoint:$endpoint,fetched_at:$fetched_at,symbol:(if ($symbol|length)>0 then $symbol else null end),trading_date:$trading_date},data:$data}'
}

cn::caps() {
  echo "announcements"
}

cn::_plate() {
  case "$1" in
    6*) echo "sse" ;;
    0*|3*) echo "szse" ;;
    *) echo "sse" ;;  # default
  esac
}

cn::_orgid() {
  # 巨潮 stock 检索：根据股票代码反查 orgId
  local code="$1"
  local url="http://www.cninfo.com.cn/new/information/topSearch/detailOfQuery"
  local resp
  resp=$(curl -fsSL --max-time 10 \
    -X POST -H "User-Agent: $CN_UA" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "keyWord=${code}&maxSecNum=10&maxListNum=5" \
    "$url" 2>/dev/null) || { echo ""; return 1; }
  printf '%s' "$resp" | jq -r --arg code "$code" '.keyBoardList[]? | select(.code == $code) | .orgId' | head -n1
}

cn::announcements() {
  local code="$1"
  local days="${2:-30}"
  local plate; plate=$(cn::_plate "$code")
  local orgid; orgid=$(cn::_orgid "$code") || true

  # 计算 seDate 范围
  local end_date; end_date=$(date +%Y-%m-%d)
  local start_date
  if date -v-${days}d +%Y-%m-%d >/dev/null 2>&1; then
    start_date=$(date -v-${days}d +%Y-%m-%d)
  else
    start_date=$(date -d "${days} days ago" +%Y-%m-%d)
  fi
  local sedate="${start_date}~${end_date}"

  local stock
  if [ -n "$orgid" ]; then
    stock="${code},${orgid}"
  else
    stock="${code},"
  fi

  local resp
  resp=$(curl -fsSL --max-time 15 \
    -X POST -H "User-Agent: $CN_UA" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "stock=${stock}&tabName=fulltext&pageSize=50&pageNum=1&category=&seDate=${sedate}&searchkey=&secid=&plate=${plate}&isHLtitle=true" \
    "http://www.cninfo.com.cn/new/hisAnnouncement/query" 2>/dev/null) \
    || { echo "cninfo: announcements query failed for $code" >&2; return 1; }

  local data; data=$(printf '%s' "$resp" | jq --arg code "$code" --arg start "$start_date" --arg end "$end_date" '
    {
      symbol: $code,
      window: {start: $start, end: $end},
      total: (.totalAnnouncement // 0),
      announcements: ((.announcements // []) | map({
        title: .announcementTitle,
        date: (.announcementTime | (./1000) | strftime("%Y-%m-%d")),
        category: .adjunctType,
        url: ("http://static.cninfo.com.cn/" + .adjunctUrl),
        is_important: ((.announcementType // "") | test("重要"))
      })),
      risk_keywords_hit: (
        ((.announcements // []) | map(.announcementTitle)) as $title_list |
        ($title_list | join(" ")) as $titles |
        {
          shareholder_reduction: ([$title_list[] | select(test("减持")) | select(test("实施完毕|期限届满|终止减持|不减持|承诺不") | not)] | length > 0),
          shareholder_reduction_completed: ([$title_list[] | select(test("减持")) | select(test("实施完毕|期限届满"))] | length > 0),
          regulatory_inquiry: ($titles | test("问询函|监管函|警示函|立案调查")),
          performance_warning: ($titles | test("预亏|大幅下滑|业绩.*下降")),
          abnormal_volatility: ($titles | test("异常波动")),
          pledge: ($titles | test("质押.*平仓|高比例质押")),
          litigation: ($titles | test("诉讼|仲裁|担保逾期"))
        }
      ),
      catalyst_keywords_hit: (
        ((.announcements // []) | map(.announcementTitle) | join(" ")) as $titles |
        {
          buyback: ($titles | test("回购")),
          major_contract: ($titles | test("中标|重大合同")),
          performance_increase: ($titles | test("预增|扭亏|业绩.*增长")),
          equity_incentive: ($titles | test("股权激励|员工持股")),
          asset_restructuring: ($titles | test("重大资产重组|资产注入"))
        }
      )
    }')
  cn::wrap_meta "announcements" "$code" "$data"
}
