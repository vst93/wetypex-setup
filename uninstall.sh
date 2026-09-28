#!/usr/bin/env bash
#
# wetypex-setup —— 卸载
#
# 默认只撤销本脚本加的东西（浮窗服务 / 键盘改动），保留软件包和你的用户数据。
# 加 --purge 才会连 fcitx5-wetypex 软件包一起删掉。
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PURGE=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
wetypex-setup 卸载

用法:
  ./uninstall.sh [选项]

选项:
  -y, --yes      不再确认
      --purge    连 fcitx5-wetypex 软件包一起卸载（用户数据仍会保留）
  -h, --help     显示本帮助

默认只做这些:
  · 停止并删除浮窗提示服务与二进制
  · 从 ~/.config/hypr/input.lua 里移除 wetypex-setup 追加的那段 kb_options
  · 从 /etc/keyd/default.conf 里移除 fn = rightcontrol
  · 提示你 fcitx5 输入法列表和 wetypex.json 的位置（不自动改，避免误删你的设置）
EOF
}

while (($#)); do
  case "$1" in
    -y|--yes) PURGE_KEEP=1; ASSUME_YES=1; shift ;;
    --purge)  PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知选项: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_DIM=""
fi
step() { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s  ·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }

confirm() {
  ((ASSUME_YES)) && return 0
  local answer
  read -r -p "$(printf '%s?%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$1")" answer || true
  [[ $answer =~ ^[Yy] ]]
}

# ── 1. 浮窗服务 ─────────────────────────────────────────────────────────────
step "移除语音浮窗提示"
systemctl --user disable --now wetypex-voice-osd.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/wetypex-voice-osd.service"
rm -f "$HOME/.local/bin/wetypex-voice-osd" "$HOME/.local/bin/wetypex-voice-osd.py.bak"
systemctl --user daemon-reload >/dev/null 2>&1 || true
ok "服务与二进制已删除"

# ── 2. Hyprland kb_options ──────────────────────────────────────────────────
step "还原 Hyprland 键盘选项"
INPUT_LUA="$HOME/.config/hypr/input.lua"
if [[ -f $INPUT_LUA ]] && grep -q '── wetypex-setup' "$INPUT_LUA"; then
  cp -a "$INPUT_LUA" "$INPUT_LUA.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$INPUT_LUA" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
cleaned = re.sub(
    r"\n*-- ── wetypex-setup[^\n]*\n.*?-- ── wetypex-setup end[^\n]*\n?",
    "\n", text, flags=re.DOTALL)
path.write_text(cleaned.rstrip() + "\n", encoding="utf-8")
PY
  if command -v hyprctl >/dev/null; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
  warn "已移除脚本追加的 kb_options 段 —— 注意 Omarchy 默认值里仍含"
  warn "shift:both_capslock_cancel，Shift 中英切换会重新失效。"
  ok "input.lua 已还原（备份见同目录 .bak.*）"
else
  info "input.lua 里没有本脚本追加的内容，跳过"
fi

# ── 3. keyd ─────────────────────────────────────────────────────────────────
step "还原 keyd 的 Fn 映射"
KEYD_CONF=/etc/keyd/default.conf
if sudo grep -q '^fn *= *rightcontrol' "$KEYD_CONF" 2>/dev/null; then
  if confirm "从 $KEYD_CONF 移除 fn = rightcontrol？"; then
    sudo cp -a "$KEYD_CONF" "$KEYD_CONF.bak.$(date +%Y%m%d%H%M%S)"
    sudo sed -i '/^fn *= *rightcontrol/d; /^# wetypex-setup: Fn 映射/d' "$KEYD_CONF"
    sudo systemctl restart keyd
    ok "Fn 映射已移除（Fn 键恢复原状）"
  fi
else
  info "没有找到本脚本写入的 fn 映射，跳过"
fi

# ── 4. 语音尾巴补丁 ─────────────────────────────────────────────────────────
step "移除「松手后补录」补丁"
if sudo test -x /usr/local/bin/wetypex-patch-voice-tail 2>/dev/null; then
  sudo /usr/local/bin/wetypex-patch-voice-tail --revert 2>/dev/null || true
  sudo rm -f /usr/local/bin/wetypex-patch-voice-tail
fi
sudo rm -f /etc/pacman.d/hooks/wetypex-voice-tail.hook
info "补录时长配置保留在 ~/.config/wetypex-setup/voice-tail（不需要可直接删）"
ok "补丁、pacman 钩子、补丁脚本已移除"

# ── 5. 软件包 ──────────────────────────────────────────────────────────────
step "软件包"
if ((PURGE)); then
  if confirm "卸载 fcitx5-wetypex 软件包？"; then
    sudo pacman -Rns --noconfirm fcitx5-wetypex
    ok "已卸载"
  fi
else
  info "保留 fcitx5-wetypex（要删掉请加 --purge）"
fi

# ── 6. 提醒 ─────────────────────────────────────────────────────────────────
step "还需要你手动确认的东西"
cat <<EOF

  这些文件本脚本没有动，因为里面可能混着你自己的设置：

    ~/.config/fcitx5/profile         输入法列表（删掉 Name=wetypex 那一段即可）
    ~/.config/fcitx5/wetypex.json    WeTypeX 配置
    ~/.config/fcitx5/config          fcitx5 全局配置

  用户数据（删掉会丢失配对身份和用户词库，确认不需要再删）：

    ~/.local/share/fcitx5-wetypex/   原版核心 / 账户 / 词库 / 语音缓存

  修改完之后重启输入法：

    systemctl --user restart omarchy-fcitx5.service
    # 或者
    fcitx5 -rd

EOF
ok "卸载流程结束"
