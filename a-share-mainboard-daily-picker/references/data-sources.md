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

| 业务 endpoint | 对应脚本 | 主源 | Fallback | 备注 |
|---|---|---|---|---|
| 实时行情 | `quote.sh <code>` | eastmoney | itick → browser | 含现价、开高低收、涨跌、成交量、换手率 |
| K 线 + 均线 | `kline.sh <code> [days] [period]` | eastmoney | itick → browser | 脚本已计算 ma5/10/20/60 + 5D/20D/60D 涨幅 + 均量 |
| 指数行情 | `index_quote.sh <sh\|sz\|cyb>` | eastmoney | itick → browser | |
| 概念/行业板块榜 | `sector_rank.sh [concept\|industry]` | eastmoney | browser | iTick 不支持板块概念，**A 股专属信号** |
| 板块成分股 | `sector_constituents.sh <board_code>` | eastmoney | browser | 同上 |
| 板块 K 线 | `sector_kline.sh <board_code> [days]` | eastmoney | browser | 看板块持续性 |
| 涨停板池 | `limit_up_pool.sh [date]` | eastmoney | browser | 含连板高度、封板时间、封板资金、行业归类 |
| 跌停板池 | `limit_down_pool.sh [date]` | eastmoney | browser | |
| 北向资金 | `north_flow.sh` | eastmoney | browser | 沪股通+深股通双向 |
| 龙虎榜 | `dragon_tiger.sh [date]` | eastmoney | browser | T+1 数据，下午发布 |
| 公告（巨潮） | `announcements.sh <code> [days]` | cninfo | browser | 含 risk/catalyst keyword 自动检测 |
| 财务核心字段 | `financials.sh <code>` | eastmoney | browser | 8 期：营收/归母/扣非/毛利率/ROE/同比 |

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

### iTick API（官方稳定 fallback）
- **地位**：当东财非官方接口出问题时的后备
- **覆盖**：A 股 quote / K 线 / 指数 / 公司基本信息（含 PE / 市值）
- **不覆盖**：A 股专属信号（涨停板/龙虎榜/北向/板块/财务三表/巨潮公告）
- **配额**：免费 5 req/min（很紧）— 仅在主源失败时调，不是日常使用
- **使用前置**：`export ITICK_TOKEN=xxx`；不设 token 时 adapter 直接报错

### Finnhub（占位 — 美股/港股 future）
- **现状**：A 股几乎全军覆没（K 线 Premium、quote 仅美股、新闻仅北美、insider 不覆盖中国）
- **保留**：未来用户加美股/港股 skill 时直接复用同一架构
- **使用前置**：`export FINNHUB_TOKEN=xxx`

### agent-browser（最后兜底）
- **何时用**：东财 + iTick 都失败时
- **怎么用**：先 `agent-browser skills get core` 拿最新指令，再去对应站点截图/抽 DOM
- **必须标注**："数据缺口"+"低置信度"——agent-browser 数据稳定性最差
- **不归档**：截图读完即弃，对话内嵌即可

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

agent 看到脚本退出码非零，应该按以下顺序：

1. **重试 1 次**（瞬时网络抖动）
2. 仍失败 → **切 SOURCE**：`SOURCE=itick ./scripts/data/<name>.sh ...`（需 ITICK_TOKEN）
3. iTick 也挂 → **agent-browser 兜底**（先 `agent-browser skills get core`）
4. 全挂 → 在报告"数据缺口"段写明哪个 endpoint 失败、走了什么 fallback、当前置信度

**任何情况下，不能编造数据**。缺数据就在报告里写"数据缺口 X"，并降低该候选的置信度（或直接不入选）。
