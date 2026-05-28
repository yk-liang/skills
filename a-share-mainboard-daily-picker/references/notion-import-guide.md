# Notion 经验导入指南

当用户后续把新的 Notion 复盘内容贴出来时，按以下流程沉淀进 skill。

## 接受的输入形式
- Notion `Export → Markdown & CSV` 的 zip
- 直接粘贴 Notion 页面文本
- 公开 Notion 页面 URL（用 agent-browser 拉）

## 合并流程
1. 通读所有新内容
2. 去重（与 `experience-notes.md` 已有规则比对）
3. 分类每条**有用**的经验：
   - Hard exclusion（直接剔除）
   - Score adjustment（评分加减分）
   - Review checklist（必须 explicit 检查的项）
   - Output style preference（输出格式偏好）
   - **Case study**（具体一笔交易的复盘 → 追加到 `case-library.md`）
4. **拒绝或降级**：纯情绪发泄、事后诸葛、无法核验的传闻、个人偏好之外的"市场猜测"
5. 把清洗后的规则追加到 `experience-notes.md`
6. 如果规则改变了**每日工作流** → 同步更新 `SKILL.md`
7. 如果规则改变了**评分阈值** → 同步更新 `scoring.md`
8. 如果规则提供了**新模式样本** → 追加到 `case-library.md`

## 导入完成后的报告
向用户汇报：
- 新增 N 条硬过滤规则
- 新增 N 条评分调整规则
- 新增 N 条检查项
- 新增 N 个案例
- 哪些原始经验**没有**沉淀（说明原因，例如"纯情绪""无法验证""与已有规则重复"）

## Notion 页面结构（参考用户当前结构）
```
股票每日复盘/
├── 经验总结        # 选股、做T、仓位、买卖点 → 主要进 playbooks.md / experience-notes.md
├── 大盘            # 黄白线 + ABC 级 + 五眼框架 → playbooks.md
├── 均线            # 均线启动票型 → playbooks.md (票型 6)
├── 缠论            # 逆市不跌 → playbooks.md (票型 7)
├── 股票大作手摘录  # 哲学层面，作为风险提醒，不直接成规则
├── 两句忠告        # 顶层心法，引用即可
└── （日期复盘）    # 单笔交易复盘 → case-library.md
```

## 常见陷阱
- 用户写"应该 / 必须"时往往是反复强调过的硬规则；写"可以 / 也许"时是软规则
- 用户写"这种以后不要做了"= Hard exclusion，要落到 case-library + experience-notes 两处
- 用户写"下次可以试试"= 仅保留为 review checklist，不作为 exclusion
- 用户引用大作手摘录的某段 = 大概率是希望体现成 risk reminder，不一定是新规则
