# Scripts (可选)

这个 skill 主要靠 agent-browser 通过浏览器拉数据，不依赖本地脚本。

如果你后续接通了数据 API（akshare / Tushare / Wind 等），可以把数据获取脚本放在这里：

- `fetch_market_summary.py` — 拉指数、涨停、连板数据
- `fetch_holdings_kline.py` — 拉持仓的 K 线 + 均线计算
- `fetch_announcements.py` — 拉巨潮公告

## 不要让脚本替代源头核验

API 数据可能滞后或缺失，公告日期、定期报告必须仍以巨潮 / 交易所为准。

## 注意事项

- akshare 等开源库的接口经常变动，运行前先 `pip show akshare` 看版本
- 不要在脚本里硬编码账户信息或 cookie
- 任何脚本运行失败 → 走 agent-browser fallback，不要在报告里编数据

---

## 当前状态：未启用

skill v1 完全靠 agent-browser。本目录留作未来扩展位。
