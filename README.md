# yk-liang/skills

个人 Claude Code skills 集合。

## 当前 skills

| 名字 | 描述 |
|---|---|
| [a-share-mainboard-daily-picker](./a-share-mainboard-daily-picker/) | A 股主板晚间复盘 + 明日预案 skill。基于 agent-browser 抓东方财富/同花顺/巨潮的原始页面，输出大盘 ABC 级判定、情绪温度、板块阶段、持仓诊断、明日候选池与操作预案。 |

## 安装

每个 skill 是独立子目录。Claude Code 支持**两种安装位置**，按 skill 的作用域选：

### 全局安装（所有项目可用）
适用于跨项目通用的 skill（如 update-config、init 这种）。
```bash
ln -s ~/AiCodingWorkspace/skills/<skill> ~/.claude/skills/<skill>
```

### 项目级安装（仅在特定项目目录下的 session 可用）
适用于**项目独立性强**的 skill（如 a-share-mainboard-daily-picker 只在炒股项目里用）。
```bash
mkdir -p <project>/.claude/skills
ln -s ~/AiCodingWorkspace/skills/<skill> <project>/.claude/skills/<skill>
```

### 首次 clone
```bash
mkdir -p ~/AiCodingWorkspace && cd ~/AiCodingWorkspace
git clone git@github.com:yk-liang/skills.git
```

### 怎么选？
- **跨项目复用** → 全局
- **依赖特定项目数据**（如 a-share 需读 stock 项目下的 holdings.md / reports/）→ **项目级**（避免在其他项目里误触发）
- **隐私敏感**（含账户信息、个人经验）→ 项目级（限定作用域）

## 当前各 skill 的推荐位置

| skill | 推荐位置 | 理由 |
|---|---|---|
| a-share-mainboard-daily-picker | `~/AiCodingWorkspace/stock/.claude/skills/` | 仅炒股用；含账户金额/具体亏损案例 |

## 开发流程

```bash
cd ~/AiCodingWorkspace/skills
# 改 skill 源文件（symlink 让 Claude Code 实时看到改动，不论装在全局还是项目级）
git add <skill>
git commit -m "<skill>: 改了什么"
git push
```

无论 symlink 装在哪，源始终是 `~/AiCodingWorkspace/skills/<skill>/`，编辑这里即可。

## 仓库约定

- 每个 skill 必须有自己的 `SKILL.md`，按照 [skill-creator](https://github.com/anthropic-experimental/skill-creator) 规范写 frontmatter
- skill 内部目录建议：`SKILL.md` + `references/` + `templates/` + `scripts/` + `evals/`
- skill 中如包含个人化数据（账户金额、具体交易复盘等）→ 仓库保持 **private**
