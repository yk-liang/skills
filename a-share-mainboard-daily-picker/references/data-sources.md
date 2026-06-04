# 数据源架构与职责矩阵

skill 所有数据获取**必须**通过 `scripts/data/` 下的脚本。本文件解释架构思路、各 adapter 职责、fallback 顺序、单位约定。脚本怎么用见 `scripts/data/README.md`。

## 总则：只用原始可信数据

**不允许使用任何"AI 中介"型数据源**（同花顺 i问财、各类 AI 选股助手、ChatGPT 插件、券商 AI 助手）。这类工具会用大模型对查询做语义解析、对结果做摘要重写，**真值会被改写**——这是 skill 不可接受的失真来源。

只允许：
1. 直接 curl 真实数据站点的**后台 JSON API**（券商前端调的那些 endpoint）
2. 必要时用 agent-browser 兜底（截图给 vision；**不归档**截图）
3. 数据冲突时回到**最权威源**：公告 → 交易所原文；行情 → 多源交叉

每个脚本输出都带 `meta.source` + `meta.fetched_at`，报告写"东财 22:14 抓"直接拼出来即可。

## Endpoint × Adapter 职责矩阵

| 业务 endpoint | 对应脚本 | 默认 fallback chain | 备注 |
|---|---|---|---|
| 实时行情 | `quote.sh <code>` | **eastmoney → 10jqka → akshare → itick → playwright** | 5 道防线 |
| K 线 + 均线 | `kline.sh <code> [days] [period]` | **eastmoney → 10jqka → akshare → itick → playwright** | 5 道防线，已含 ma5/10/20/60 + 5D/20D/60D 涨幅 + 均量 |
| 指数行情 | `index_quote.sh <sh\|sz\|cyb>` | **eastmoney → 10jqka → akshare → itick → playwright** | 5 道防线 |
| 涨停板池 | `limit_up_pool.sh [date]` | **10jqka → eastmoney → akshare** | 10jqka 优先（中文 ladder_label 更直观）|
| 跌停板池 | `limit_down_pool.sh [date]` | eastmoney | 失败需 agent 手动 `SOURCE=playwright` |
| 概念/行业板块榜 | `sector_rank.sh [concept\|industry]` | **eastmoney → playwright** | akshare 同路径风控；playwright 浏览器 fetch 救场 |
| 板块成分股 | `sector_constituents.sh <board_code>` | **eastmoney → playwright** | 同上 |
| 板块 K 线 | `sector_kline.sh <board_code> [days]` | **eastmoney → playwright** | 同上 |
| 沪深港通当日 | `north_flow.sh` | **akshare → eastmoney** | ⚠️ 北向每日数据 2024-08-19 起停披；`north_deprecated:true` 是正常状态；用南向 + 龙虎榜机构代理 |
| 北向资金历史 | `north_flow_history.sh [days]` | **akshare** | 仅历史回看（2014–2024-08-18 有效，之后 null） |
| 龙虎榜 | `dragon_tiger.sh [date]` | **akshare → eastmoney** | akshare 走不同 URL 比 datacenter 稳 |
| 公告（巨潮） | `announcements.sh <code> [days]` | cninfo | 含 risk/catalyst keyword 自动检测 |
| 财务核心字段 | `financials.sh <code>` | **eastmoney → akshare** | 8 期主要指标 |
| 财务完整三表 | `financials_full.sh <code>` | **akshare** | 资产负债 + 利润 + 现金流原始字段 |
| 业绩预告 | `earnings_forecast.sh [date]` | **akshare** | 新能力 |
| 个股基础信息 | `individual_info.sh <code>` | **akshare → eastmoney → playwright** | 市值/行业/上市日期/总股本 |

## 数据源对比

### 东方财富后台 JSON API（主源）
- **地位**：A 股数据最完整、免费、无 token、覆盖全部 A 股专属信号
- **优点**：涨停板池、龙虎榜、北向、概念板块——这些**只有它有**
- **缺点**：非官方接口、字段编码反直觉（f43=价格×100、f168=换手率×10000）、偶尔会有反爬变化
- **风险缓解**：所有字段解码在 `lib/eastmoney.sh` 内部，对外暴露人类可读单位；接口变化时只改一个文件
- **价格还原**：adapter 内部统一 `÷100` 还原为元；adapter 对外暴露**人类可读单位**（元 / 百分比 / 手）

### 巨潮资讯网（公告专用）
- **地位**：A 股公告**唯一权威源**（监管机构指定信息披露平台）
- **覆盖**：所有上市公司公告、定期报告、问询函回复、减持/回购/异动公告
- **adapter**：`lib/cninfo.sh`，POST 到 `/new/hisAnnouncement/query`
- **关键词检测**：announcements 输出已自动检测 risk_keywords_hit（减持/质押/问询/异动/诉讼）和 catalyst_keywords_hit（回购/中标/增发/激励）

### 同花顺（一级 fallback + 涨停池首选）
- **地位**：东财 push2 风控时的第一道防线，并作为涨停池的**首选**（中文 high_days 比东财字段更直观）
- **覆盖**：quote / kline（含 PE）/ index_quote / limit_up_pool
- **优势**：
  - 无 token、无 cookie、和东财 IP 风控独立
  - 涨停池含 `ladder_label` 中文标签（"首板"/"2连板"/"3天3板"/"7天5板"）+ `reason_type`（涨停原因）+ `today_intraday_breaks`（开板次数）
- **限制**：
  - 涨停池 limit 上限 200
  - 不支持板块榜、北向、财务报表

### AKShare（二级 fallback + 救场源）
- **地位**：当 eastmoney/10jqka 都挂时的下一层，且对**龙虎榜/北向/财务三表/业绩预告**作主源（这些场景 akshare 实测更稳）
- **覆盖**：kline / limit_up_pool / dragon_tiger / north_flow / financials_full / earnings_forecast / individual_info
- **优势**：
  - 开源 Python 库，无 token
  - 多源融合（一个挂自动切另一个）
  - 龙虎榜走不同 URL（不依赖 datacenter），稳定拿到 90+ 条
  - 北向资金升级版含上涨/下跌家数（赚钱效应数据）
  - 财务三表 102 期完整历史
- **限制**：
  - 内部对板块榜/quote/全量股票也是 push2 同路径，**救不了板块榜**
  - 启动 0.5-1s（Python 加载）
  - 部分 endpoint 同样会偶发风控
- **使用前置**：`pip3 install akshare`

### Playwright（终极兜底）
- **地位**：所有 API 源都挂时启动真浏览器，绕过 IP 风控
- **覆盖**：通过 mixin 复用 eastmoney.sh 的全部 endpoint（quote / kline / sector_rank 等）
- **核心机制**：
  - 启动 chromium → goto 东财页建立合法 session
  - 用 `page.request.fetch()` 调东财 JSON API（带浏览器 cookies，绕过 CORS 限制）
  - 输出原始 JSON，复用 eastmoney 的 jq 解析逻辑
- **优势**：
  - **任何东财 endpoint 都能救**（实测 sector_rank 4s 成功，curl 完全拿不到）
  - 比 agent-browser 快 50-100x（无需 LLM agent loop）
  - 比 agent-browser 准确（不是看截图猜，是真的 JSON）
- **限制**：
  - 启动 chromium ~1.5s + fetch ~0.5s = 单次 ~3-5s
  - 需要 `pip3 install playwright && python3 -m playwright install chromium`（chromium 约 100MB）
- **人工验证模式**：`export PW_HEADED=1` → 浏览器可见，可看到 agent 真的抓到了什么

### iTick API（备用付费源）
- **地位**：当 eastmoney+10jqka+akshare+playwright 都挂时的额外保险（极少触发）
- **覆盖**：A 股 quote / K 线 / 指数 / 公司基本信息
- **配额**：免费 5 req/min（很紧）
- **使用前置**：`export ITICK_TOKEN=xxx`

### Finnhub（占位 — 美股/港股 future）
- **现状**：A 股几乎全军覆没（K 线 Premium、quote 仅美股、新闻仅北美、insider 不覆盖中国）
- **保留**：未来用户加美股/港股 skill 时直接复用同一架构
- **使用前置**：`export FINNHUB_TOKEN=xxx`

### agent-browser（已退役为应急工具）
- **何时用**：Playwright 都装不上或全部 5 层失败时的最后手段（极罕见）
- **历史**：v1 时这是主兜底，现已被 Playwright 替代（更快更准更可重复）
- **怎么用**：先 `agent-browser skills get core` 拿最新指令，再去对应站点截图/抽 DOM
- **必须标注**："数据缺口"+"低置信度"

## 拒绝来源

- ❌ **同花顺 i问财、AI 选股、券商 AI**——任何 LLM 中介
- ❌ 股吧、雪球热帖、东方财富股吧
- ❌ 公众号、知乎、小红书
- ❌ 短视频截图、群聊截图、朋友推荐
- ❌ 未署名"市场传闻""听说"
- ❌ 隔夜消息但当日大盘已反映过的旧文章

## 数据完整性检查

每只候选股必须能交叉验证：

1. **代码归属**：前缀符合主板（600/601/603/605/000/001/002/003），不在排除清单（adapter 提供 `em::is_mainboard` 工具）
2. **价格一致**：默认 chain 命中 eastmoney 后，数据源单一；若 fallback 到 iTick → 可对照前一日东财收盘做合理性校验
3. **财报口径**：扣非净利润 vs 经营现金流偏离 > 30% → 警惕"利润高但现金没回来"（应收账款堆积）
4. **公告与行情**：今天大涨但近 30 日无公告且板块不在主线 → 标记"无逻辑放量"，进回避池
5. **板块归属**：sector_rank 的概念板块 vs 行业板块归类如有差异，以**领涨股板块**为准

## 单位与字段约定（已在 adapter 层处理）

为方便 agent 直接用脚本输出，**adapter 内部已做单位转换**，对外暴露：

- 价格、涨跌、开高低收 → **元**（保留 2 位小数）
- 涨跌幅、换手率、毛利率、ROE → **百分比数字**（如 5.21 表示 5.21%）
- 成交量 → **手**（保留整数）
- 成交额 → **元**（保留整数）
- 时间戳 → ISO 8601 本地时间（含 `+08:00` 偏移）

## 失败处理与降级（agent 行为约定）

**默认链已自动 fallback**（见上方矩阵）。agent 看到脚本 stderr 出现 `dispatch: fallback succeeded with X` 就知道走了备援；看到 `dispatch: all sources in chain failed` 才需要手动兜底：

1. 如果是 quote/kline/index_quote 完全失败（东财+同花顺+iTick 都挂）→ **agent-browser 兜底**（先 `agent-browser skills get core`），并在报告写"数据来源：agent-browser（已降级）"
2. 如果是 sector_rank / sector_constituents 持续风控 → 等 5–30 分钟或直接 agent-browser 兜底
3. 报告"数据缺口"段写明哪个 endpoint 失败、走了什么 fallback、当前置信度

**任何情况下，不能编造数据**。缺数据就在报告里写"数据缺口 X"，并降低该候选的置信度（或直接不入选）。

## 连板字段语义（必读 — 历史踩过的坑）

涨停池里的连板字段含义微妙：

| 字段 | 含义 | "7天5板" | "3天3板" | "首板" |
|---|---|---|---|---|
| `ladder_label` | 同花顺中文标签 | "7天5板" | "3天3板" | "首板" |
| `consecutive_limit_up` | **真连板数**（严格）| **null** | 3 | 1 |
| `streak_height` | 题材热度（窗口涨停次数）| 5 | 3 | 1 |
| `is_pure_streak` | 纯连板 | false | true | true |

**判断"连板梯队"用 `consecutive_limit_up`**；判断"题材热度"用 `streak_height`。两者经常不同。

历史教训（2026-06-03 报告）：
- 利仁 001259（"首板"）被 agent 误读为 "9 板"（因为老字段 `ladder_count=9` 实际是 18 天里 9 次涨停的窗口数）
- 红星 600367（"7天5板"，真连板 3）被 agent 误读为 "5 连板"
