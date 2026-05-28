# yk-liang/skills

个人 Claude Code skills 集合。

## 当前 skills

| 名字 | 描述 |
|---|---|
| [a-share-mainboard-daily-picker](./a-share-mainboard-daily-picker/) | A 股主板晚间复盘 + 明日预案 skill。基于 agent-browser 抓东方财富/同花顺/巨潮的原始页面，输出大盘 ABC 级判定、情绪温度、板块阶段、持仓诊断、明日候选池与操作预案。 |

## 安装

每个 skill 是一个独立子目录，安装方式是把它符号链接到 `~/.claude/skills/`：

```bash
# 1. clone 到本地工作目录（仅首次）
mkdir -p ~/AiCodingWorkspace
cd ~/AiCodingWorkspace
git clone git@github.com:yk-liang/skills.git

# 2. 把要启用的 skill symlink 到 ~/.claude/skills/
ln -s ~/AiCodingWorkspace/skills/a-share-mainboard-daily-picker ~/.claude/skills/a-share-mainboard-daily-picker

# 3. 重启 Claude Code（或开新 session），skill 就能被识别和触发
```

## 开发流程

```bash
cd ~/AiCodingWorkspace/skills
# 改 skill 源文件 …（symlink 让 Claude Code 实时看到改动）
git add <skill>
git commit -m "<skill>: 改了什么"
git push
```

## 仓库约定

- 每个 skill 必须有自己的 `SKILL.md`，按照 [skill-creator](https://github.com/anthropic-experimental/skill-creator) 规范写 frontmatter
- skill 内部目录建议：`SKILL.md` + `references/` + `templates/` + `scripts/` + `evals/`
- skill 中如包含个人化数据（账户金额、具体交易复盘等）→ 仓库保持 **private**
