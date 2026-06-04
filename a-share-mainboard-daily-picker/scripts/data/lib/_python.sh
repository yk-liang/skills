#!/usr/bin/env bash
# Python 路径解析器 — 所有 adapter 共用
#
# 优先级（高 → 低）:
# 1. <skill_root>/.skill-env 文件     （setup.sh 创建后写入的 python 绝对路径）
# 2. $SKILL_PYTHON 环境变量          （用户手动指定，调试用）
# 3. <skill_root>/.venv/bin/python3   （skill 本地 venv，兼容老安装）
# 4. <skill_root>/.conda-env/bin/python3  （conda prefix env 在 skill 本地）
# 5. python3                          （系统 / 当前 shell 的 python3，最后兜底）
#
# .skill-env 是个单行文本文件，记录的是 python 可执行文件的绝对路径。
# 这样支持：conda named env (~/miniforge3/envs/...)、conda prefix、venv、自定义
# 任何环境管理方式都能识别。

skill_python() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local skill_root
  skill_root="$(cd "$script_dir/.." && pwd)"

  # 1. .skill-env marker 文件
  if [ -f "${skill_root}/.skill-env" ]; then
    local p
    p=$(head -n1 "${skill_root}/.skill-env" | tr -d '[:space:]')
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  fi

  # 2. 环境变量
  if [ -n "${SKILL_PYTHON:-}" ] && [ -x "$SKILL_PYTHON" ]; then
    echo "$SKILL_PYTHON"
    return 0
  fi

  # 3. 本地 venv
  if [ -x "${skill_root}/.venv/bin/python3" ]; then
    echo "${skill_root}/.venv/bin/python3"
    return 0
  fi

  # 4. 本地 conda prefix env
  if [ -x "${skill_root}/.conda-env/bin/python3" ]; then
    echo "${skill_root}/.conda-env/bin/python3"
    return 0
  fi

  # 5. 系统 python3
  echo "python3"
}
