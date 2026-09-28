#!/usr/bin/env bash
#
# wetypex-setup —— 在 Linux 上装好「微信输入法（WeTypeX）+ Fn 按住说话 + 音量波形浮窗」
#
# 幂等：重复执行安全，不会重复写入配置。
# 安全：改动任何文件前先备份；不覆盖用户已有的自定义配置。
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF_VERSION="1.0.1"
# 预编译浮窗二进制的下载来源（fork 之后改成自己的仓库）
readonly GITHUB_REPO="vst93/wetypex-setup"

# ── 选项 ────────────────────────────────────────────────────────────────────
ASSUME_YES=0        # -y
WANT_FN=1           # --no-fn 关闭：把 Fn 映射成右 Ctrl
WANT_CAPS=0         # --capslock 开启：把 Compose 从 CapsLock 挪到右 Alt
WANT_STATUS=1       # --no-statusbar 关闭：修补状态栏输入法插件
KEEP_DEFAULT=0      # --keep-default 开启：不把 wetypex 设为默认输入法
ARCHIVE=""          # --archive <WeType_2.2.3_657.zip>
SKIP_PKGS=0         # --no-packages 开启：跳过系统包安装

usage() {
  cat <<'EOF'
wetypex-setup —— 微信输入法（WeTypeX）一键安装

用法:
  ./install.sh [选项]

选项:
  -y, --yes              不再逐项确认
      --archive <路径>   使用已下载的官方包 WeType_2.2.3_657.zip
      --no-fn            不把 Fn 映射成右 Ctrl（跳过 keyd 那一步）
      --capslock         顺便恢复 CapsLock 键（Compose 挪到右 Alt）
      --keep-default     不把 wetypex 设为默认输入法
      --no-statusbar     不修补状态栏的输入法插件
      --no-packages      跳过系统依赖包的安装
  -h, --help             显示本帮助

它会依次做这些事:
  1. 安装依赖包 + fcitx5-wetypex（GitHub Release，校验 SHA256）
  2. 提取官方运行时（fcitx5-wetypex-setup）
  3. 写 ~/.config/fcitx5/wetypex.json（Shift 中英切换 / Fn 按住说话）
  4. 把 wetypex 加进 ~/.config/fcitx5/profile
  5. 修键盘: 去掉会破坏 Shift 切换的 shift:both_capslock_cancel
  6. keyd: Fn -> 右 Ctrl
  7. 编译安装音量波形浮窗 + systemd 用户服务
  8. 修补状态栏输入法插件（如果装了）
EOF
}

while (($#)); do
  case "$1" in
    -y|--yes)          ASSUME_YES=1; shift ;;
    --archive)         ARCHIVE="${2:-}"; shift 2 ;;
    --no-fn)           WANT_FN=0; shift ;;
    --capslock)        WANT_CAPS=1; shift ;;
    --keep-default)    KEEP_DEFAULT=1; shift ;;
    --no-statusbar)    WANT_STATUS=0; shift ;;
    --no-packages)     SKIP_PKGS=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "未知选项: $1" >&2; usage; exit 1 ;;
  esac
done

# ── 日志 ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi
step()  { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info()  { printf '%s  ·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn()  { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

confirm() {
  ((ASSUME_YES)) && return 0
  local answer
  read -r -p "$(printf '%s?%s %s [Y/n] ' "$C_YELLOW" "$C_RESET" "$1")" answer || true
  [[ -z $answer || $answer =~ ^[Yy] ]]
}

# 备份文件，回显备份路径
backup_file() {
  local file="$1"
  [[ -e $file ]] || return 0
  local dest="$file.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$file" "$dest"
  printf '%s' "$dest"
}

# ── 环境检查 ────────────────────────────────────────────────────────────────
step "检查环境"
[[ $(uname -m) == "x86_64" ]] || die "WeTypeX 官方运行时只提供 x86-64"
command -v pacman >/dev/null || die "目前只支持 Arch 系发行版（需要 pacman）。
  Debian/Ubuntu 请用官方 .deb，Fedora 请用 .rpm，然后手动执行本脚本的第 3~8 步。"
command -v python3 >/dev/null || die "需要 python3"
ok "Arch 系发行版 / x86-64 / python3"

IS_OMARCHY=0
[[ -d /usr/share/omarchy && -x /usr/share/omarchy/bin/omarchy ]] && IS_OMARCHY=1
if ((IS_OMARCHY)); then
  ok "检测到 Omarchy（浮窗会用系统自带的 OSD）"
else
  warn "没检测到 Omarchy —— 浮窗会退回用 notify-send 桌面通知"
fi

# 提前拿一次 sudo 凭据：装包和改 keyd 都要用。
# 拿不到（比如从非交互环境跑）就跳过那两步，而不是中途失败。
SUDO_AVAILABLE=0
if sudo -n true 2>/dev/null; then
  SUDO_AVAILABLE=1
elif [[ -t 0 ]] && sudo -v 2>/dev/null; then
  SUDO_AVAILABLE=1
fi
if ((SUDO_AVAILABLE)); then
  ok "已获得 sudo 权限"
else
  warn "拿不到 sudo 权限 —— 装包和 keyd 那两步会被跳过"
  warn "请在有终端的会话里重新运行本脚本，或手动执行那两步"
fi

# ── 1. 依赖包 ───────────────────────────────────────────────────────────────
if ((SKIP_PKGS)); then
  step "跳过系统依赖包安装（--no-packages）"
else
  step "安装系统依赖包"
  DEPS=(fcitx5 fcitx5-qt libime libc++ json-c curl bubblewrap python
        qt6-base qt6-svg qt6-webengine wl-clipboard pipewire ffmpeg libnotify polkit)
  MISSING=()
  for pkg in "${DEPS[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
  done
  if ((${#MISSING[@]})); then
    info "需要安装: ${MISSING[*]}"
    if ((SUDO_AVAILABLE == 0)); then
      warn "没有 sudo 权限，跳过。请手动执行："
      warn "  sudo pacman -S --needed ${MISSING[*]}"
    elif confirm "用 pacman 安装这些包？"; then
      sudo pacman -S --needed --noconfirm "${MISSING[@]}"
      ok "依赖已安装"
    else
      die "依赖不全会导致插件加载失败"
    fi
  else
    ok "依赖齐全"
  fi
fi

# ── 2. 安装 fcitx5-wetypex ──────────────────────────────────────────────────
step "安装 fcitx5-wetypex"
if pacman -Qq fcitx5-wetypex >/dev/null 2>&1; then
  ok "已安装: $(pacman -Q fcitx5-wetypex)"
else
  TMPDIR_DL="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_DL"' EXIT
  if ((SUDO_AVAILABLE == 0)); then
    warn "没有 sudo 权限，无法安装软件包。请手动执行："
    warn "  yay -S fcitx5-wetypex    （或从 GitHub Release 下载后用 sudo pacman -U）"
    TMPDIR_DL=""
  else
  info "查询 GitHub 最新 Release ..."
  API="https://api.github.com/repos/panxuc/fcitx5-wetypex/releases/latest"
  if ! RELEASE_JSON="$(curl -fsSL "$API")"; then
    die "无法访问 GitHub API。可以改用 AUR：yay -S fcitx5-wetypex"
  fi
  PKG_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(next(a["browser_download_url"] for a in d["assets"]
           if a["name"].endswith("-x86_64.pkg.tar.zst")))')"
  SUMS_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(next((a["browser_download_url"] for a in d["assets"]
            if a["name"] == "SHA256SUMS"), ""))')"
  PKG_NAME="$(basename "$PKG_URL")"
  info "下载 $PKG_NAME"
  curl -fsSL -o "$TMPDIR_DL/$PKG_NAME" "$PKG_URL"
  if [[ -n $SUMS_URL ]]; then
    curl -fsSL -o "$TMPDIR_DL/SHA256SUMS" "$SUMS_URL"
    ( cd "$TMPDIR_DL" && grep -F "$PKG_NAME" SHA256SUMS | sha256sum -c - >/dev/null ) \
      || die "SHA256 校验失败，已中止"
    ok "SHA256 校验通过"
  else
    warn "发布页没有 SHA256SUMS，跳过校验"
  fi
  sudo pacman -U --noconfirm "$TMPDIR_DL/$PKG_NAME"
  ok "fcitx5-wetypex 已安装"
  fi
fi

# ── 3. 官方运行时 ───────────────────────────────────────────────────────────
step "准备官方运行时（输入核心 + 词典 + 界面资源）"
core_ready() {
  fcitx5-wetypex-setup --check 2>/dev/null | grep -q '"core_ready": *true'
}
if core_ready; then
  ok "运行时已就绪"
elif [[ -n $ARCHIVE ]]; then
  [[ -f $ARCHIVE ]] || die "找不到文件: $ARCHIVE"
  fcitx5-wetypex-setup --archive "$ARCHIVE"
  ok "已从 $ARCHIVE 提取"
elif confirm "从腾讯官方地址下载固定版本包？(约 307MB，等同于接受上游许可)"; then
  fcitx5-wetypex-setup --download --accept-upstream-license
  ok "运行时已准备"
else
  die "没有运行时，输入法无法工作。可稍后手动执行：
    fcitx5-wetypex-setup --download --accept-upstream-license"
fi
core_ready || die "运行时校验失败，请执行 fcitx5-wetypex-setup --check 查看缺什么"

# ── 4. WeTypeX 配置 ─────────────────────────────────────────────────────────
step "写入 WeTypeX 配置"
WETYPEX_JSON="$HOME/.config/fcitx5/wetypex.json"
mkdir -p "$(dirname "$WETYPEX_JSON")"
B="$(backup_file "$WETYPEX_JSON")"; [[ -n $B ]] && info "已备份到 $(basename "$B")"
python3 - "$WETYPEX_JSON" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

# 只补默认值，不覆盖用户已经调过的项
data.setdefault("clipboard_enabled", True)
data.setdefault("shift_switch", True)          # Shift 切换中英文
data.setdefault("voice_hold_shortcut", True)
data.setdefault("voice_hold_key", "Control_R") # 配合 keyd 的 Fn -> 右 Ctrl
data.setdefault("voice_launch_key",
                "Control+Super+Shift_L,Control+Shift+Super_L,Super+Shift+Control_L")
data.setdefault("voice_microphone", "自动检测")

path.write_text(json.dumps(data, ensure_ascii=False, indent=4) + "\n", encoding="utf-8")
print("    " + ", ".join(f"{k}={v}" for k, v in sorted(data.items())))
PY
ok "wetypex.json 已更新（已存在的设置保持不变）"

# ── 5. fcitx5 profile ───────────────────────────────────────────────────────
step "把 wetypex 加进 fcitx5 输入法列表"

fcitx5_stop() {
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^omarchy-fcitx5.service'; then
    systemctl --user stop omarchy-fcitx5.service 2>/dev/null || true
  fi
  pkill -f '^/usr/bin/fcitx5' 2>/dev/null || true
  sleep 1
}
fcitx5_start() {
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^omarchy-fcitx5.service'; then
    # 这个 unit 是 Type=dbus，而 session bus 在 Arch 上是 dbus-broker（不支持
    # SystemdService=），所以只要服务不在跑、又有客户端请求 org.fcitx.Fcitx5，
    # bus 就会按 /usr/share/dbus-1/services/ 直接拉一个游离实例跟 systemd 抢名字。
    # 循环「杀干净 → 立刻启动」，通常一两次就能抢到。
    for _ in $(seq 1 10); do
      pkill -f '^/usr/bin/fcitx5' 2>/dev/null || true
      sleep 1
      systemctl --user reset-failed omarchy-fcitx5.service 2>/dev/null || true
      systemctl --user start omarchy-fcitx5.service 2>/dev/null || true
      sleep 3
      local main owner
      main="$(systemctl --user show -p MainPID --value omarchy-fcitx5.service 2>/dev/null)"
      owner="$(busctl --user list 2>/dev/null | awk '$1=="org.fcitx.Fcitx5"{print $2}')"
      if [[ -n $main && $main != 0 && $main == "$owner" ]]; then
        return 0
      fi
    done
    warn "fcitx5 服务没能稳定起来（DBus 名字被游离实例抢了）。手动修复："
    warn "  pkill fcitx5; systemctl --user start omarchy-fcitx5.service"
  else
    (fcitx5 -d --disable notificationitem >/dev/null 2>&1 &) || true
    sleep 2
  fi
}

PROFILE="$HOME/.config/fcitx5/profile"
mkdir -p "$(dirname "$PROFILE")"
fcitx5_stop
B="$(backup_file "$PROFILE")"; [[ -n $B ]] && info "已备份到 $(basename "$B")"
KEEP_DEFAULT="$KEEP_DEFAULT" python3 - "$PROFILE" <<'PY'
import os, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
keep_default = os.environ.get("KEEP_DEFAULT") == "1"

if path.exists():
    lines = path.read_text(encoding="utf-8").splitlines()
else:
    lines = ["[Groups/0]", "Name=Default", "Default Layout=us", "DefaultIM=",
             "", "[GroupOrder]", "0=Default"]

# 找出第一个 group 里的输入法条目
item_re = re.compile(r"^\[Groups/(\d+)/Items/(\d+)\]$")
group = None
items = {}          # (group, index) -> name
for line in lines:
    m = item_re.match(line.strip())
    if m:
        group = (int(m.group(1)), int(m.group(2)))
        items[group] = ""
    elif group and line.startswith("Name="):
        items[group] = line.split("=", 1)[1].strip()
        group = None

names = set(items.values())
if "wetypex" in names:
    print("    wetypex 已在列表中")
else:
    first_group = 0
    indices = [idx for (g, idx) in items if g == first_group]
    next_index = max(indices) + 1 if indices else 0
    block = [f"[Groups/{first_group}/Items/{next_index}]",
             "# Name", "Name=wetypex", "# Layout", "# Layout=", ""]
    try:
        insert_at = next(i for i, l in enumerate(lines) if l.strip() == "[GroupOrder]")
    except StopIteration:
        insert_at = len(lines)
    lines[insert_at:insert_at] = block
    print(f"    已添加 wetypex（Items/{next_index}）")

if not keep_default:
    for i, line in enumerate(lines):
        if line.startswith("DefaultIM="):
            if line.strip() != "DefaultIM=wetypex":
                lines[i] = "DefaultIM=wetypex"
                print("    DefaultIM -> wetypex")
            break

path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
fcitx5_start
ok "输入法列表已更新"

# ── 6. 键盘：修 Shift 切换 ──────────────────────────────────────────────────
step "修键盘选项（Shift 中英切换）"
if ! command -v hyprctl >/dev/null; then
  warn "没有 hyprctl（非 Hyprland 环境），跳过。"
  warn "如果你也在 Hyprland 下，请手动确认 kb_options 不含 shift:both_capslock_cancel"
else
  INPUT_LUA="$HOME/.config/hypr/input.lua"
  if [[ ! -f $INPUT_LUA ]]; then
    warn "找不到 $INPUT_LUA，跳过"
  elif grep -q 'kb_options' "$INPUT_LUA"; then
    warn "$INPUT_LUA 里已经有 kb_options，跳过以免覆盖你的设置"
    warn "请自行确认它不包含 shift:both_capslock_cancel"
  else
    CURRENT="$(hyprctl getoption input:kb_options 2>/dev/null | sed -n 's/^str: *//p')"
    SANITIZED="$(printf '%s' "$CURRENT" | tr ',' '\n' \
      | sed 's/^ *//; s/ *$//' \
      | grep -v '^shift:both_capslock' | grep -v '^$' | paste -sd, -)"
    if ((WANT_CAPS)); then
      SANITIZED="$(printf '%s' "$SANITIZED" | tr ',' '\n' \
        | sed 's/^compose:caps$/compose:ralt/' | paste -sd, -)"
    fi
    if [[ $SANITIZED == "$CURRENT" ]]; then
      ok "kb_options 无需修改（$CURRENT）"
    else
      B="$(backup_file "$INPUT_LUA")"; [[ -n $B ]] && info "已备份到 $(basename "$B")"
      cat >> "$INPUT_LUA" <<EOF

-- ── wetypex-setup ───────────────────────────────────────────────────────────
-- 去掉 shift:both_capslock_cancel。它把 Shift 键定义成
--     key <LFSH> { type="ALPHABETIC", symbols=[ Shift_L, Caps_Lock ] }
-- ALPHABETIC 类型在 Shift 修饰位生效时选第 2 级，于是 Shift 的“松开”事件
-- 在 fcitx5 里被算成 Caps_Lock 而不是 Shift_L。输入法判断“同一个修饰键按下
-- 再松开”要求两次键名一致，于是永远匹配不上 → Shift 切换中英文失效。
hl.config({
  input = {
    kb_options = "$SANITIZED",
  },
})
-- ── wetypex-setup end ───────────────────────────────────────────────────────
EOF
      hyprctl reload >/dev/null 2>&1 || true
      ERRORS="$(hyprctl configerrors 2>/dev/null || true)"
      if [[ -n $ERRORS ]]; then
        warn "Hyprland 报了配置错误："; printf '%s\n' "$ERRORS" >&2
      else
        ok "kb_options: $CURRENT  →  $SANITIZED"
      fi
    fi
  fi
fi

# ── 7. keyd: Fn -> 右 Ctrl ──────────────────────────────────────────────────
step "配置 Fn 按住说话"
if ((WANT_FN == 0)); then
  info "已跳过（--no-fn）"
elif ! command -v keyd >/dev/null; then
  warn "没装 keyd，跳过。想用 Fn 按住说话的话：
    sudo pacman -S keyd && sudo systemctl enable --now keyd
    然后在 /etc/keyd/default.conf 里加 fn = rightcontrol"
elif ((SUDO_AVAILABLE == 0)); then
  warn "没有 sudo 权限，跳过 keyd 配置。请手动执行："
  warn "  sudo sh -c 'printf \"\\n[main]\\nfn = rightcontrol\\n\" >> /etc/keyd/default.conf'"
  warn "  sudo systemctl restart keyd"
else
  KEYD_CONF=/etc/keyd/default.conf
  if sudo grep -q '^fn *= *rightcontrol' "$KEYD_CONF" 2>/dev/null; then
    ok "keyd 已经映射过 fn -> rightcontrol"
  elif sudo test -s "$KEYD_CONF" && sudo grep -q '^\[main\]' "$KEYD_CONF"; then
    warn "$KEYD_CONF 里已有 [main] 段，跳过以免覆盖你的映射"
    warn "请手动加入一行：fn = rightcontrol"
  elif sudo test -s "$KEYD_CONF"; then
    sudo cp -a "$KEYD_CONF" "$KEYD_CONF.bak.$(date +%s)"
    printf '\n# wetypex-setup: Fn 映射成右 Ctrl，供 WeTypeX 的“按住说话”使用\n[main]\nfn = rightcontrol\n' \
      | sudo tee -a "$KEYD_CONF" >/dev/null
    sudo systemctl restart keyd
    ok "已追加 fn = rightcontrol"
  else
    sudo install -Dm600 "$SCRIPT_DIR/files/keyd-default.conf" "$KEYD_CONF"
    sudo systemctl restart keyd
    ok "已写入 $KEYD_CONF"
  fi
fi

# ── 8. 音量波形浮窗 ─────────────────────────────────────────────────────────
step "安装语音浮窗提示（音量波形）"
mkdir -p "$HOME/.local/bin"
OSD_BIN="$HOME/.local/bin/wetypex-voice-osd"
OSD_BUILT=0

# 优先从源码编译 —— 不用信任下载来的二进制
if command -v cargo >/dev/null; then
  info "用 cargo 从源码编译 ..."
  if ( cd "$SCRIPT_DIR/voice-osd" && cargo build --release --quiet ); then
    install -m755 "$SCRIPT_DIR/voice-osd/target/release/wetypex-voice-osd" "$OSD_BIN"
    ok "已从源码编译安装（$(stat -c%s "$OSD_BIN") 字节）"
    OSD_BUILT=1
  else
    warn "cargo 编译失败，改试下载预编译版本"
  fi
else
  info "没找到 cargo，改试下载预编译版本"
fi

# 没有 Rust 工具链就下载 CI 编译好的二进制
if ((OSD_BUILT == 0)); then
  info "从 GitHub Release 获取预编译二进制 ..."
  OSD_URL="$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(next((a["browser_download_url"] for a in d.get("assets", [])
                if a["name"] == "wetypex-voice-osd-x86_64"), ""))
except Exception:
    print("")' )"
  if [[ -n $OSD_URL ]]; then
    curl -fsSL -o "$OSD_BIN.new" "$OSD_URL"
    install -m755 "$OSD_BIN.new" "$OSD_BIN"
    rm -f "$OSD_BIN.new"
    ok "已下载预编译版本（$(stat -c%s "$OSD_BIN") 字节）"
  else
    die "既没有 cargo，也拿不到预编译二进制。
    装个 Rust 再重跑即可：  sudo pacman -S rust"
  fi
fi

install -Dm644 "$SCRIPT_DIR/files/wetypex-voice-osd.service" \
  "$HOME/.config/systemd/user/wetypex-voice-osd.service"
systemctl --user daemon-reload
systemctl --user enable wetypex-voice-osd.service >/dev/null 2>&1 || true
systemctl --user restart wetypex-voice-osd.service
sleep 1
if systemctl --user is-active --quiet wetypex-voice-osd.service; then
  ok "浮窗服务已启动（按住 Fn 时会显示波形）"
else
  warn "浮窗服务没起来，看看：journalctl --user -u wetypex-voice-osd -n 30"
fi

# ── 9. 状态栏插件 ───────────────────────────────────────────────────────────
step "修补状态栏输入法插件"
PANEL="$HOME/.config/omarchy/plugins/unseencurtain.languages/Panel.qml"
if ((WANT_STATUS == 0)); then
  info "已跳过（--no-statusbar）"
elif [[ ! -f $PANEL ]]; then
  info "没装 unseencurtain.languages 插件，跳过"
  info "（它的输入法列表是写死的，装了之后状态栏会一直显示 EN）"
else
  RIME_FLAG=()
  grep -q '^Name=rime' "$PROFILE" 2>/dev/null && RIME_FLAG=(--with-rime)
  python3 "$SCRIPT_DIR/extras/patch-statusbar-languages.py" "$PANEL" "${RIME_FLAG[@]}" || true
  if command -v omarchy-restart-shell >/dev/null; then
    omarchy-restart-shell >/dev/null 2>&1 || true
    ok "已重启状态栏"
  fi
fi

# ── 完成 ────────────────────────────────────────────────────────────────────
step "完成"
cat <<EOF

  现在的效果：

    按住 Fn 说话，松开  →  屏幕底部浮窗显示
                            󰍬 ▁▃▅▇▆▄▂▃ 正在聆听…
                            󰍬 识别中…
                            󰍬 ✓ 识别出的文字

    Shift              →  中英文切换
    Ctrl + Space       →  英文键盘 ↔ 中文输入法

  还需要你手动做的一步（可选）：
    云端候选 / 设备同步 / 语音识别都需要配对账户
      fcitx5-wetypex-settings   → 账户/设备 → 生成六位匹配码
      再用手机微信输入法扫码绑定

  常用命令：
    fcitx5-wetypex-settings          完整设置窗口
    fcitx5-wetypex-setup --check     检查官方运行时
    fcitx5-remote -n                 当前输入法
    systemctl --user status wetypex-voice-osd   浮窗服务状态

EOF
ok "全部完成（wetypex-setup v$SELF_VERSION）"
