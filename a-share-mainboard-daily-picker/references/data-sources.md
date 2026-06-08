# 数据源架构

skill 所有数据获取**必须**通过 `scripts/data/` 下的脚本。Fallback chain、字段约定、失败处理详见 `scripts/data/README.md`。本文件只记各数据源的**定位与优缺点**。

## 总则

只用原始可信数据。**禁止任何 LLM 中介型数据源**（i问财、AI 选股助手、ChatGPT 插件）。

---

## 数据源对比

### 东方财富后台 JSON API（主源）
- A 股数据最完整、免费、无 token、覆盖涨停池/龙虎榜/概念板块等专属信号
- 字段编码反直觉（f43=价格×100），adapter 内部已还原为人类可读单位
- 偶发 IP 风控（push2/clist 路径），dispatcher 自动 fallback

### 巨潮资讯网（公告专用）
- A 股公告**唯一权威源**（监管指定信息披露平台）
- `lib/cninfo.sh`，含 risk/catalyst keyword 自动检测
- 减持字段已区分"新减持"vs"实施完毕"

### 同花顺（一级 fallback + 涨停池首选）
- 东财风控时第一道防线，涨停池**首选**（中文 ladder_label 更直观）
- 含 `reason_type`（涨停原因标签，仅作辅助参考）
- 无 token、无 cookie、与东财 IP 风控独立
- 不支持板块榜、财务

### AKShare（二级 fallback + 龙虎榜/北向/财务主源）
- 开源 Python 库，龙虎榜走不同 URL（比东财 datacenter 稳）
- 财务三表完整历史、业绩预告
- 北向资金已停披但历史数据可回看
- 内部对板块榜也是 push2 路径，**救不了板块榜**
- 需 `pip3 install akshare`

### Playwright（终极兜底）
- 启动真浏览器 + `page.request.fetch()` 绕 IP 风控
- 复用 eastmoney URL + jq 解析，任何东财 endpoint 都能救
- 比 agent-browser 快 50-100x（真 JSON，非截图猜）
- 需 `pip3 install playwright && python3 -m playwright install chromium`

### iTick API（备用付费源）
- 免费 5 req/min，仅覆盖 quote/kline/index
- 需 `export ITICK_TOKEN=xxx`

### Finnhub（占位 — 美股/港股 future）
- A 股几乎全军覆没，保留给未来美股/港股 skill 复用

### agent-browser（已退役为应急）
- Playwright 都失败时的最后手段（极罕见）
- 必须标注"数据缺口"+"低置信度"
