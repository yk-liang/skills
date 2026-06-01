# 数据层（scripts/data/）

skill 的所有数据获取都通过本目录的脚本进行。**SKILL 主体不允许直接 curl、不允许直接调 agent-browser**——因为：

1. 数据真实性：脚本读后台 JSON API，返回原始结构化数据，不经过 LLM 解析改写
2. 可重复：同样输入 → 同样输出
3. 可演进：换数据源只需加 adapter，skill 主体不动
4. 诚实失败：脚本出错就 exit 非零、不输出，agent 看到空就知道要走兜底或报"数据缺口"

## 目录结构

```
scripts/data/
├── README.md                # 本文档（设计 + adapter 协议 + 加新 adapter 步骤）
├── lib/
│   ├── eastmoney.sh         # 东方财富 adapter（A 股主力）
│   ├── cninfo.sh            # 巨潮资讯 adapter（公告）
│   ├── 10jqka.sh            # 同花顺 adapter（交叉验证）
│   └── finnhub.sh           # finnhub adapter（占位 — 将来给美股/港股用，A 股不走这条）
├── quote.sh <code>                      # 实时行情
├── kline.sh <code> [days] [period]      # K 线（含 5/10/20/60 均线计算）
├── index_quote.sh <index>               # 指数行情（上证 / 深证 / 创业板）
├── sector_rank.sh [type]                # 板块涨幅榜（concept/industry）
├── sector_constituents.sh <board_code>  # 板块成分股
├── sector_kline.sh <board_code> [days]  # 板块 K 线（看持续性）
├── limit_up_pool.sh [date]              # 涨停板池（含连板高度、封板时间）
├── limit_down_pool.sh [date]            # 跌停板池
├── north_flow.sh                        # 北向资金净流入
├── dragon_tiger.sh [date]               # 龙虎榜
├── announcements.sh <code> [days]       # 巨潮公告
└── financials.sh <code>                 # 财务核心字段
```

## 统一输出 Schema

每个脚本必须输出符合以下结构的 JSON 到 stdout：

```json
{
  "meta": {
    "source": "eastmoney",          // adapter 名
    "endpoint": "quote",            // 业务 endpoint
    "fetched_at": "2026-06-01T22:14:33+08:00",   // ISO 8601 本地时间
    "symbol": "600519",             // 若适用
    "trading_date": "2026-06-01"    // 数据所属交易日
  },
  "data": { ... }                   // 业务数据
}
```

**为什么必须有 meta**：agent 写报告时要标"东财 22:14 抓"，meta.fetched_at + meta.source 直接拼出来。换源时只有 meta.source 变化，agent 行为不变。

## Adapter 协议

`lib/<source>.sh` 是 source-shell library，必须导出以下函数（每个 adapter 都要实现）。函数返回 0 = 成功，非零 = 失败。

```bash
# 必备：能力声明（用于自动选源）
em::caps()                                  # echo "quote kline index_quote sector_rank ..."

# 必备：A 股专属/通用 endpoint 实现（按需）
em::quote <code>                            # 实时行情
em::kline <code> <days> <period>            # K 线（period: 1d/5m/15m/30m/60m/1w/1mo）
em::index_quote <index>                     # 指数（sh / sz / cyb）
em::sector_rank <type>                      # 板块榜（concept / industry）
em::sector_constituents <board_code>        # 成分股
em::sector_kline <board_code> <days>        # 板块 K
em::limit_up_pool [date]                    # 涨停池
em::limit_down_pool [date]                  # 跌停池
em::north_flow                              # 北向
em::dragon_tiger [date]                     # 龙虎榜
em::announcements <code> <days>             # 公告（也可由 cninfo adapter 实现）
em::financials <code>                       # 财务

# 工具函数
em::secid <code>                            # 600519 → 1.600519，000001 → 0.000001
em::is_mainboard <code>                     # 0 主板 / 1 非主板（便于过滤）
em::wrap_meta <endpoint> <symbol> <data>    # 包 meta 头
```

每个顶层脚本（如 `quote.sh`）做的事：

```bash
#!/usr/bin/env bash
set -euo pipefail
SOURCE="${SOURCE:-eastmoney}"               # 默认源，可被环境变量覆盖
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/${SOURCE}.sh"
em::quote "$1"                              # 调 adapter，stdout 输出已含 meta 的 JSON
```

## 添加新 adapter（如未来加 Tushare / iFinD / wind）

1. 在 `lib/` 加 `<name>.sh`，实现协议中能涉及的函数（不必全实现，但必须先 `em::caps` 声明能力）
2. 不实现的函数可定义为 `return 1`，让顶层脚本根据 caps 决定 fallback
3. 顶层脚本通过 `SOURCE=<name>` 环境变量选用
4. 不需要改 SKILL.md 和任何 skill 主体逻辑

## 失败处理与降级

agent 看到脚本退出码非零，应该：

1. 先重试 1 次（瞬时网络抖动）
2. 仍失败 → 切换 SOURCE（例如 `SOURCE=10jqka`）
3. 全挂 → 用 agent-browser 兜底（仅在此情况下）+ 标记"低置信度"
4. 任何情况下，**不能编造数据**，缺数据就在报告里写"数据缺口 X"

## 单位与字段约定（避免每次都查文档）

东财后台 API 有几个反直觉的单位规则：

- 价格字段（如 `f43`, `f44` 等）= 实际价格 × 100。adapter 必须**还原成元再返回**
- 涨跌幅字段（如 `f3`, `f170`）= 实际百分比 × 100（即 5.21% 在原始 JSON 里是 521）
- 成交量单位 = **手**（1 手 = 100 股）
- 成交额单位 = **元**
- 换手率 `f168` = 万分比 × 100（即 1.23% 在原始里是 12300，需要 ÷10000）

adapter 内部做单位转换，对外暴露**人类可读单位**：

- 价格、涨跌、开高低收 → 元（保留 2 位小数）
- 涨跌幅、换手率 → 百分比（如 5.21）
- 成交量 → 手（保留整数）
- 成交额 → 元（保留整数）

## 时间约定

- `meta.fetched_at`：脚本运行时刻，ISO 8601 本地时间（含 `+08:00` 偏移）
- `meta.trading_date`：数据所属交易日（YYYY-MM-DD）。盘后跑 → 当日；盘前跑 → 上一交易日
- 节假日 / 周末跑 → 自动用上一交易日（每个 adapter 自己处理）

## 反爬与 UA

东财、巨潮、同花顺都需要常见的浏览器 UA。adapter 统一在 `lib/<source>.sh` 里设置：

```bash
EM_UA="${EM_UA:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36}"
```

如果某个 endpoint 开始返回反爬页面 / 403，**不要乱加 cookie / token**——先去看 README 是否有更新版本，或者切换 SOURCE。

## 测试快路径

```bash
cd ~/AiCodingWorkspace/skills/a-share-mainboard-daily-picker
./scripts/data/quote.sh 600519             # 应输出含 meta 的 JSON
./scripts/data/index_quote.sh sh           # 上证
./scripts/data/limit_up_pool.sh            # 当日涨停池
./scripts/data/sector_rank.sh concept | jq '.data.sectors[:5]'   # 概念板块前 5
```

## 已知限制 / 风控注意

东财 `/api/qt/clist/get` 这条路径（sector_rank、sector_constituents 用）**容易触发 IP 级反爬**——表现为持续返回空响应。可能原因：
- 短时间内重复调用同一 fs 参数
- IP 被加入临时黑名单（通常 5–30 分钟自动解封）

**当 sector_rank / sector_constituents 持续失败时**：

1. 等待 5–30 分钟自然解封
2. 切 `SOURCE=itick`（注意 iTick 不支持 sector）→ 失败
3. → **走 agent-browser 兜底**（按 SKILL.md Step 5 流程，agent 打开东财板块页 `http://quote.eastmoney.com/center/boardlist.html` 抽 DOM）

`/api/qt/stock/get`（quote、index_quote 用）和 `/api/qt/stock/kline/get`（kline 用）**未见风控**。`push2ex.eastmoney.com`（涨停板池）和 `datacenter.eastmoney.com`（财务、龙虎榜）也独立稳定。
