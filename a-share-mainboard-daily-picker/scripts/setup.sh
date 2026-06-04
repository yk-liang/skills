#!/usr/bin/env bash
# A-share skill 依赖安装与检查脚本
#
# 用法：
#   ./scripts/setup.sh              交互式安装（推荐首次跑）
#   ./scripts/setup.sh --check      只检测，输出 JSON 到 stdout，给 agent 解析用
#   ./scripts/setup.sh --yes        非交互全装（默认推荐选项 conda named env + akshare + playwright）
#
# 环境管理优先级（默认推荐）：
#   1) detected conda → conda named env (~/<conda_root>/envs/a-share-skill)
#      理由：C 依赖预编译（pandas/numpy/lxml）、python 版本可选、ARM Mac 原生
#   2) no conda → venv (.venv)
#   3) 用户也可选 venv / conda prefix / 直接装到 base（不推荐）
#
# 安装完成后会写 <skill>/.skill-env 文件，记录 python 路径
# 所有 adapter 通过 lib/_python.sh 读这个 marker 自动找到正确环境

set -euo pipefail

CHECK_ONLY=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --yes)   ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
  esac
done

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="a-share-skill"   # conda named env 的默认名

# ---------- 工具函数 ----------

# 读 .skill-env 拿 python 路径
get_target_python() {
  if [ -f "${SKILL_ROOT}/.skill-env" ]; then
    local p; p=$(head -n1 "${SKILL_ROOT}/.skill-env" | tr -d '[:space:]')
    [ -x "$p" ] && { echo "$p"; return; }
  fi
  if [ -x "${SKILL_ROOT}/.venv/bin/python3" ]; then echo "${SKILL_ROOT}/.venv/bin/python3"; return; fi
  if [ -x "${SKILL_ROOT}/.conda-env/bin/python3" ]; then echo "${SKILL_ROOT}/.conda-env/bin/python3"; return; fi
  command -v python3 || echo ""
}

get_target_pip() {
  local py; py=$(get_target_python)
  [ -z "$py" ] && { echo ""; return; }
  local pip_path="$(dirname "$py")/pip3"
  [ -x "$pip_path" ] || pip_path="$(dirname "$py")/pip"
  [ -x "$pip_path" ] && echo "$pip_path" || echo "pip3"
}

env_kind() {
  # 判断当前 python 在哪种环境
  if [ ! -f "${SKILL_ROOT}/.skill-env" ]; then
    if [ -d "${SKILL_ROOT}/.venv" ]; then echo "venv-local"; return; fi
    if [ -d "${SKILL_ROOT}/.conda-env" ]; then echo "conda-prefix-local"; return; fi
    echo "system"; return
  fi
  local p; p=$(head -n1 "${SKILL_ROOT}/.skill-env" | tr -d '[:space:]')
  case "$p" in
    *miniforge*/envs/*|*anaconda*/envs/*|*miniconda*/envs/*) echo "conda-named" ;;
    *${SKILL_ROOT}/.venv*) echo "venv-local" ;;
    *${SKILL_ROOT}/.conda-env*) echo "conda-prefix-local" ;;
    *) echo "custom" ;;
  esac
}

detect_all() {
  if command -v curl >/dev/null 2>&1; then CURL_OK=1; CURL_VER=$(curl --version | head -1 | awk '{print $2}'); else CURL_OK=0; CURL_VER=""; fi
  if command -v jq   >/dev/null 2>&1; then JQ_OK=1;   JQ_VER=$(jq --version | sed 's/jq-//'); else JQ_OK=0; JQ_VER=""; fi

  SYS_PY=$(command -v python3 || echo "")
  SYS_PY_VER=""; [ -n "$SYS_PY" ] && SYS_PY_VER=$("$SYS_PY" --version 2>&1 | awk '{print $2}')

  HAS_CONDA=0; CONDA_VER=""; CONDA_ROOT=""
  if command -v conda >/dev/null 2>&1; then
    HAS_CONDA=1
    CONDA_VER=$(conda --version 2>&1 | awk '{print $2}')
    CONDA_ROOT=$(conda info --base 2>/dev/null || echo "")
  fi

  TARGET_PY=$(get_target_python)
  TARGET_PY_VER=""; [ -n "$TARGET_PY" ] && TARGET_PY_VER=$("$TARGET_PY" --version 2>&1 | awk '{print $2}')
  ENV_KIND=$(env_kind)

  if [ -n "$TARGET_PY" ] && "$TARGET_PY" -c "import akshare" 2>/dev/null; then
    AK_INSTALLED=1; AK_VER=$("$TARGET_PY" -c "import akshare; print(akshare.__version__)" 2>/dev/null)
  else
    AK_INSTALLED=0; AK_VER=""
  fi

  PW_LIB_INSTALLED=0; PW_CHROMIUM_INSTALLED=0
  if [ -n "$TARGET_PY" ] && "$TARGET_PY" -c "import playwright" 2>/dev/null; then
    PW_LIB_INSTALLED=1
    if [ -d "$HOME/Library/Caches/ms-playwright" ] && ls "$HOME/Library/Caches/ms-playwright" 2>/dev/null | grep -qi chromium; then
      PW_CHROMIUM_INSTALLED=1
    fi
  fi

  ITICK_TOKEN_SET=0; [ -n "${ITICK_TOKEN:-}" ] && ITICK_TOKEN_SET=1
}

compute_enabled_adapters() {
  ENABLED=("eastmoney" "10jqka" "cninfo")
  DISABLED_NAMES=(); DISABLED_HINTS=()
  [ "$AK_INSTALLED" = "1" ] && ENABLED+=("akshare") || { DISABLED_NAMES+=("akshare"); DISABLED_HINTS+=("./scripts/setup.sh"); }
  if [ "$PW_LIB_INSTALLED" = "1" ] && [ "$PW_CHROMIUM_INSTALLED" = "1" ]; then
    ENABLED+=("playwright")
  else
    DISABLED_NAMES+=("playwright"); DISABLED_HINTS+=("./scripts/setup.sh")
  fi
  [ "$ITICK_TOKEN_SET" = "1" ] && ENABLED+=("itick") || { DISABLED_NAMES+=("itick"); DISABLED_HINTS+=("export ITICK_TOKEN=xxx"); }
}

# ---------- --check 模式 ----------

if [ "$CHECK_ONLY" = "1" ]; then
  detect_all
  compute_enabled_adapters
  jq -n \
    --arg curl_ver "$CURL_VER" --argjson curl_ok "$CURL_OK" \
    --arg jq_ver "$JQ_VER" --argjson jq_ok "$JQ_OK" \
    --arg sys_py "$SYS_PY" --arg sys_py_ver "$SYS_PY_VER" \
    --argjson has_conda "$HAS_CONDA" --arg conda_ver "$CONDA_VER" --arg conda_root "$CONDA_ROOT" \
    --arg target_py "$TARGET_PY" --arg target_py_ver "$TARGET_PY_VER" --arg env_kind "$ENV_KIND" \
    --argjson ak_ok "$AK_INSTALLED" --arg ak_ver "$AK_VER" \
    --argjson pw_lib "$PW_LIB_INSTALLED" --argjson pw_chrome "$PW_CHROMIUM_INSTALLED" \
    --argjson itick_set "$ITICK_TOKEN_SET" \
    --argjson enabled "$(printf '%s\n' "${ENABLED[@]}" | jq -R . | jq -s .)" \
    --argjson disabled_names "$(printf '%s\n' "${DISABLED_NAMES[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    --argjson disabled_hints "$(printf '%s\n' "${DISABLED_HINTS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{
      required: {
        curl: {installed: ($curl_ok == 1), version: $curl_ver},
        jq: {installed: ($jq_ok == 1), version: $jq_ver},
        system_python3: {installed: ($sys_py | length > 0), path: $sys_py, version: $sys_py_ver}
      },
      conda: {installed: ($has_conda == 1), version: $conda_ver, root: $conda_root},
      target_env: {
        python_path: $target_py,
        python_version: $target_py_ver,
        kind: $env_kind
      },
      optional: {
        akshare: {installed: ($ak_ok == 1), version: $ak_ver},
        playwright: {lib_installed: ($pw_lib == 1), chromium_installed: ($pw_chrome == 1)},
        itick: {token_set: ($itick_set == 1)}
      },
      enabled_adapters: $enabled,
      disabled_adapters: [range(0; ($disabled_names | length)) as $i | {name: $disabled_names[$i], install_hint: $disabled_hints[$i]}]
    }'
  exit 0
fi

# ---------- 交互模式 ----------

ask_yn() {
  local prompt="$1" default="${2:-N}"
  if [ "$ASSUME_YES" = "1" ]; then
    echo "$prompt [--yes → y]"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$default"
  read -r ans
  ans="${ans:-$default}"
  case "$ans" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

ask_input() {
  local prompt="$1" default="$2"
  if [ "$ASSUME_YES" = "1" ]; then
    echo "$default"
    return
  fi
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read -r ans
  echo "${ans:-$default}"
}

ask_choice() {
  local prompt="$1" default="$2" choices="$3"
  if [ "$ASSUME_YES" = "1" ]; then
    echo "$default"
    return
  fi
  printf '%s [%s, 默认 %s]: ' "$prompt" "$choices" "$default" >&2
  read -r ans
  echo "${ans:-$default}"
}

echo "==============================================="
echo "  A 股选股 skill — 依赖安装与检查"
echo "  skill 根目录: $SKILL_ROOT"
echo "==============================================="
echo ""

detect_all

# === 必需依赖 ===
echo "[必需依赖]"
printf "  curl    "; [ "$CURL_OK" = "1" ] && echo "✓ $CURL_VER" || { echo "✗ 未安装。请装：brew install curl"; exit 1; }
printf "  jq      "; [ "$JQ_OK"   = "1" ] && echo "✓ $JQ_VER"   || { echo "✗ 未安装。请装：brew install jq"; exit 1; }
printf "  python3 "; [ -n "$SYS_PY" ] && echo "✓ $SYS_PY_VER ($SYS_PY)" || { echo "✗ 未安装"; exit 1; }
echo ""

# === 环境管理 ===
echo "[Step 1] Python 环境管理"
echo "  原则：所有 Python 依赖装在 skill 专属环境，不污染全局 / conda base"
echo ""

if [ -f "${SKILL_ROOT}/.skill-env" ]; then
  echo "  ✓ 已配置环境: $TARGET_PY ($TARGET_PY_VER)"
  echo "    类型: $ENV_KIND"
  echo "    marker 文件: ${SKILL_ROOT}/.skill-env"
  if ask_yn "  是否重建环境？(y/N)" "N"; then
    rm -f "${SKILL_ROOT}/.skill-env"
    NEED_CREATE=1
  else
    NEED_CREATE=0
  fi
else
  NEED_CREATE=1
fi

if [ "$NEED_CREATE" = "1" ]; then
  echo ""
  echo "  选环境管理方式："
  if [ "$HAS_CONDA" = "1" ]; then
    echo "    1) [推荐] conda named env  → ${CONDA_ROOT}/envs/${ENV_NAME}"
    echo "         优势: C 依赖预编译（pandas/numpy/lxml）、python 版本可选、ARM Mac 原生"
    echo "    2) conda prefix env       → ${SKILL_ROOT}/.conda-env"
    echo "         优势: 删 skill 目录即清理；劣势: 大（数百 MB）"
    echo "    3) venv                   → ${SKILL_ROOT}/.venv"
    echo "         劣势: C 扩展需现场编译，ARM Mac 可能卡"
    echo "    4) 直接装到当前 python ($SYS_PY)（不推荐，污染全局）"
    DEFAULT_CHOICE="1"
  else
    echo "    1) venv                   → ${SKILL_ROOT}/.venv"
    echo "    2) 直接装到当前 python ($SYS_PY)（不推荐）"
    DEFAULT_CHOICE="1"
  fi
  CHOICE=$(ask_choice "  你的选择" "$DEFAULT_CHOICE" "1-4")
  echo ""

  case "$CHOICE" in
    1)
      if [ "$HAS_CONDA" = "1" ]; then
        # conda named env
        PY_VERSION=$(ask_input "  python 版本" "3.12")
        ENV_NAME_FINAL=$(ask_input "  env 名" "${ENV_NAME}")
        TARGET_DIR="${CONDA_ROOT}/envs/${ENV_NAME_FINAL}"
        echo ""
        echo "  执行: conda create -n ${ENV_NAME_FINAL} python=${PY_VERSION} -y"
        if conda create -n "$ENV_NAME_FINAL" "python=${PY_VERSION}" -y; then
          NEW_PY="${TARGET_DIR}/bin/python3"
          echo "$NEW_PY" > "${SKILL_ROOT}/.skill-env"
          echo "  ✓ conda env 创建: $NEW_PY"
        else
          echo "  ✗ 失败"; exit 1
        fi
      else
        # venv
        $SYS_PY -m venv "${SKILL_ROOT}/.venv"
        NEW_PY="${SKILL_ROOT}/.venv/bin/python3"
        echo "$NEW_PY" > "${SKILL_ROOT}/.skill-env"
        "${SKILL_ROOT}/.venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
        echo "  ✓ venv 创建: $NEW_PY"
      fi
      ;;
    2)
      if [ "$HAS_CONDA" = "1" ]; then
        # conda prefix env
        PY_VERSION=$(ask_input "  python 版本" "3.12")
        echo "  执行: conda create -p ${SKILL_ROOT}/.conda-env python=${PY_VERSION} -y"
        if conda create -p "${SKILL_ROOT}/.conda-env" "python=${PY_VERSION}" -y; then
          NEW_PY="${SKILL_ROOT}/.conda-env/bin/python3"
          echo "$NEW_PY" > "${SKILL_ROOT}/.skill-env"
          echo "  ✓ conda prefix env 创建: $NEW_PY"
        fi
      else
        # 直接装到系统
        echo "$SYS_PY" > "${SKILL_ROOT}/.skill-env"
        echo "  ⚠️  将装到系统 python: $SYS_PY"
      fi
      ;;
    3)
      $SYS_PY -m venv "${SKILL_ROOT}/.venv"
      NEW_PY="${SKILL_ROOT}/.venv/bin/python3"
      echo "$NEW_PY" > "${SKILL_ROOT}/.skill-env"
      "${SKILL_ROOT}/.venv/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
      echo "  ✓ venv 创建: $NEW_PY"
      ;;
    4)
      echo "$SYS_PY" > "${SKILL_ROOT}/.skill-env"
      echo "  ⚠️  装到系统 python: $SYS_PY"
      ;;
    *)
      echo "  无效选择，退出"; exit 1
      ;;
  esac

  detect_all   # 重检
fi

TARGET_PY=$(get_target_python)
TARGET_PIP=$(get_target_pip)
echo ""
echo "  当前 python: $TARGET_PY ($TARGET_PY_VER)"
echo "  当前 pip:    $TARGET_PIP"
echo ""

# === akshare ===
echo "[Step 2] AKShare adapter"
detect_all
if [ "$AK_INSTALLED" = "1" ]; then
  echo "  ✓ 已安装 $AK_VER"
else
  echo "  ✗ 未安装"
  echo "  价值: 龙虎榜（91 条 vs eastmoney 经常空）、北向资金升级版（含上涨/下跌家数）"
  echo "        财务三表完整 102 期、业绩预告（新能力）"
  echo "  依赖: pandas, numpy, lxml, curl_cffi 等"
  echo ""
  case "$ENV_KIND" in
    conda-named|conda-prefix-local)
      echo "  执行: conda install -p $(dirname $(dirname $TARGET_PY)) -c conda-forge pandas numpy lxml -y"
      echo "        $TARGET_PIP install akshare"
      if ask_yn "  是否安装？(y/N)" "Y"; then
        # 关键 C 依赖走 conda，akshare 本身走 pip
        ENV_PREFIX="$(dirname $(dirname $TARGET_PY))"
        conda install -p "$ENV_PREFIX" -c conda-forge pandas numpy lxml -y || true
        "$TARGET_PIP" install akshare && echo "  ✓ akshare 装好"
      fi
      ;;
    *)
      echo "  命令: $TARGET_PIP install akshare"
      if ask_yn "  是否安装？(y/N)" "Y"; then
        "$TARGET_PIP" install akshare && echo "  ✓ akshare 装好"
      fi
      ;;
  esac
fi
echo ""

# === playwright ===
echo "[Step 3] Playwright + Chromium"
detect_all
if [ "$PW_LIB_INSTALLED" = "1" ] && [ "$PW_CHROMIUM_INSTALLED" = "1" ]; then
  echo "  ✓ playwright + chromium 已装"
elif [ "$PW_LIB_INSTALLED" = "1" ]; then
  echo "  ⚠️  playwright 库已装但 chromium 没装"
  if ask_yn "  装 chromium？(y/N)" "Y"; then
    "$TARGET_PY" -m playwright install chromium && echo "  ✓ chromium 装好"
  fi
else
  echo "  ✗ 未安装"
  echo "  价值: sector_rank 板块榜（唯一救场）+ 任何东财 endpoint 绕过 IP 风控"
  echo "  命令: $TARGET_PIP install playwright"
  echo "        $TARGET_PY -m playwright install chromium  （chromium 约 100MB，~/Library/Caches/ms-playwright 全局共享）"
  echo ""
  if ask_yn "  是否安装？(y/N)" "Y"; then
    "$TARGET_PIP" install playwright && "$TARGET_PY" -m playwright install chromium && echo "  ✓ playwright + chromium 装好"
  fi
fi
echo ""

# === iTick ===
echo "[Step 4] iTick（备用付费源）"
if [ "$ITICK_TOKEN_SET" = "1" ]; then
  echo "  ✓ ITICK_TOKEN 已设置"
else
  echo "  - 未启用（可不装；启用: export ITICK_TOKEN=xxx）"
fi
echo ""

# === 总结 ===
detect_all
compute_enabled_adapters
echo "==============================================="
echo "  完成。当前启用 adapter:"
for a in "${ENABLED[@]}"; do echo "    ✓ $a"; done
if [ ${#DISABLED_NAMES[@]} -gt 0 ] && [ -n "${DISABLED_NAMES[0]:-}" ]; then
  echo "  未启用:"
  for i in "${!DISABLED_NAMES[@]}"; do
    echo "    - ${DISABLED_NAMES[$i]}: ${DISABLED_HINTS[$i]}"
  done
fi
echo "==============================================="
echo ""
echo "tip: ./scripts/setup.sh --check 输出 JSON 复检状态"
echo "tip: 重建环境: 删 .skill-env (+ 对应 .venv/.conda-env 或 conda env) → 再跑 setup"
