# wetypex-setup

在 Linux 上把 **微信输入法（WeTypeX）+ Fn 按住说话 + 实时音量波形浮窗** 一次装好。

针对 **Omarchy / Arch Linux + Hyprland + Wayland** 做了完整适配，也适用于其它 fcitx5 环境
（浮窗会自动退回桌面通知）。

```
按住 Fn 说话，松开：

    󰍬  ▁▂▃▅▇▆▄▂▃  正在聆听…        ← 实时音量波形
    󰍬  识别中…
    󰍬  ✓ 今天天气不错
```

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [环境要求](#环境要求)
- [一键安装](#一键安装)
- [安装完的效果](#安装完的效果)
- [它到底改了什么（逐条 + 原理）](#它到底改了什么逐条--原理)
- [踩坑记录](#踩坑记录)
- [手动安装（非 Arch 系统）](#手动安装非-arch-系统)
- [排错](#排错)
- [卸载](#卸载)
- [项目结构](#项目结构)
- [原项目与致谢](#原项目与致谢)
- [许可与声明](#许可与声明)

---

## 它解决什么问题

核心项目 [WeTypeX](#原项目与致谢) 让 Linux 能用上微信输入法的输入核心，但它有几个**上手就会踩的坑**，
本仓库把它们全部处理掉，并把过程中查清的**根因**记录下来：

| 问题 | 症状 | 本仓库的处理 |
| --- | --- | --- |
| **Shift 切不了中英文** | 按 Shift 完全没反应 | 改 `kb_options`，去掉 `shift:both_capslock_cancel` |
| **Fn 键没反应** | 想用 Fn 按住说话，配了也没用 | 用 keyd 把 Fn 映射成右 Ctrl |
| **`Ctrl+Win+Shift` 时灵时不灵** | 换个按键顺序就失效 | 补全 3 条按键组合，覆盖全部 6 种顺序 |
| **没有任何录音提示** | 按了快捷键屏幕上什么都不变 | 自建音量波形浮窗（本仓库的 Rust 程序） |
| **状态栏显示错误** | 一直是 "EN"，切不回来 | 修补状态栏插件的写死列表 |
| **语音识别没结果** | 录了但插不进文字 | 见[踩坑记录](#踩坑记录)第 4 条 |

---

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 架构 | **x86-64**（WeTypeX 官方运行时只有 x86-64） |
| 发行版 | **Arch 系**（脚本用 `pacman`；Debian/Fedora 见[手动安装](#手动安装非-arch-系统)） |
| 桌面 | **Hyprland + Wayland**（键盘那一步依赖 `hyprctl`；其它 Wayland 合成器见下方说明） |
| 输入法框架 | fcitx5 ≥ 5.1.9 |
| 可选 | **Omarchy**（浮窗用它的 OSD）、**keyd**（Fn 映射）、**Rust/cargo**（编译浮窗；没有就自动下载 CI 预编译好的二进制） |

> **不是 Omarchy 也能用。** 浮窗程序启动时会探测 Omarchy 的 OSD：
> 探测不到就自动退回 `notify-send` 桌面通知（只是没有波形动画）。

---

## 一键安装

```bash
git clone <这个仓库> ~/Projects/wetypex-setup
cd ~/Projects/wetypex-setup
./install.sh
```

常用选项：

```bash
./install.sh -y                     # 全部不再确认
./install.sh --archive ~/WeType_2.2.3_657.zip   # 用已下载的官方包（不联网下载）
./install.sh --capslock             # 顺便把 CapsLock 键恢复成 CapsLock
./install.sh --no-fn                # 不映射 Fn（不用 keyd）
./install.sh --no-statusbar         # 不碰状态栏插件
./install.sh --keep-default         # 不把 wetypex 设为默认输入法
./install.sh --no-packages          # 跳过系统依赖包安装
```

脚本**幂等**：重复执行安全；改动任何文件前都会备份成 `xxx.bak.时间戳`；
**不会覆盖**你已有的 `kb_options`、keyd `[main]` 段等自定义配置（遇到会跳过并提示）。

---

## 安装完的效果

| 操作 | 效果 |
| --- | --- |
| **按住 `Fn` 说话，松开** | 屏幕底部浮窗显示实时音量波形 → 识别中 → ✓ 识别出的文字 |
| **`Shift`** | 中英文切换 |
| **`Ctrl + Space`** | 英文键盘 ↔ 中文输入法 |
| **`Ctrl + Win + Shift`** | 启动语音（再按任意键结束），任意按键顺序都可以 |
| `-` / `=` | 组合输入时翻页 |
| `=` | 光标前有文本时打开「问 AI」 |
| 状态栏 | 显示 `微`（WeTypeX）/ `EN`（英文键盘） |

---

## 它到底改了什么（逐条 + 原理）

### 1. 安装 `fcitx5-wetypex`（GitHub Release，校验 SHA256）

从 [最新 Release](https://github.com/panxuc/fcitx5-wetypex/releases/latest) 取
`fcitx5-wetypex-<版本>-x86_64.pkg.tar.zst`，用发布页的 `SHA256SUMS` 校验后 `pacman -U`。
失败时可改用 AUR：`yay -S fcitx5-wetypex`。

依赖：`fcitx5 fcitx5-qt libime libc++ json-c curl bubblewrap python qt6-base qt6-svg
qt6-webengine wl-clipboard pipewire ffmpeg libnotify polkit`。

### 2. 提取官方运行时

```bash
fcitx5-wetypex-setup --download --accept-upstream-license
# 或
fcitx5-wetypex-setup --archive /path/to/WeType_2.2.3_657.zip
```

WeTypeX 不含微信输入法的任何二进制，需要从腾讯官方地址取固定的 2.2.3.657 包
（约 307 MB），提取输入核心与词典到 `~/.local/share/fcitx5-wetypex/runtime`。
`--download` 等同于接受上游许可，请自行确认。

### 3. `~/.config/fcitx5/wetypex.json`

只补默认值，**不覆盖你调过的项**：

```json
{
    "clipboard_enabled": true,
    "shift_switch": true,
    "voice_hold_shortcut": true,
    "voice_hold_key": "Control_R",
    "voice_launch_key": "Control+Super+Shift_L,Control+Shift+Super_L,Super+Shift+Control_L",
    "voice_microphone": "自动检测"
}
```

- `shift_switch` —— 让 WeTypeX 自己处理 Shift 中英切换（默认就是 true，显式写出来）
- `voice_hold_key: Control_R` —— 配合 keyd 的 Fn 映射，实现「按住 Fn 说话」
- `voice_launch_key` 三条 —— 见[踩坑记录](#踩坑记录)第 3 条

### 4. `~/.config/fcitx5/profile`

把 `wetypex` 加进当前输入法组（保留你已有的输入法），并把 `DefaultIM` 设为 `wetypex`
（用 `--keep-default` 可关闭）。

> 必须先停 fcitx5 再改：fcitx5 退出时会用自己的内存状态覆写 profile，
> 改完再启动才不会被冲掉。脚本里已经处理。

### 5. 键盘：去掉 `shift:both_capslock_cancel`

这是**最隐蔽的一个坑**，见[踩坑记录](#踩坑记录)第 1 条。脚本读取当前生效的
`input:kb_options`，只摘掉 `shift:both_capslock_cancel`（其它选项原样保留），
把结果写进 `~/.config/hypr/input.lua` 末尾，然后 `hyprctl reload` 验证。

> **注意**：Omarchy 默认用 `compose:caps` 把 CapsLock 键变成 Compose 键。
> 摘掉 shift 选项后 CapsLock 依然是 Compose。想要回 CapsLock 就加 `--capslock`，
> 脚本会把 `compose:caps` 换成 `compose:ralt`（Compose 挪到右 Alt）。

### 6. keyd：`Fn → 右 Ctrl`

见[踩坑记录](#踩坑记录)第 2 条。写入 `/etc/keyd/default.conf`：

```ini
[ids]
*

[main]
fn = rightcontrol
```

已有 `[main]` 段时会跳过并提示你手动加一行，不覆盖你的映射。

### 7. 音量波形浮窗（本仓库自己写的）

WeTypeX **完全没有录音提示界面**（见[踩坑记录](#踩坑记录)第 5 条），所以这里补一个。
程序监听 WeTypeX 写下的状态文件，把状态画成浮窗：

```text
~/.local/share/fcitx5-wetypex/state/
├── voice/recording     录音期间存在，结束即删除
├── voice/input.wav     pw-record 正在写的录音，用来算电平
├── voice/result.json   识别服务返回的原始结果（ok / text）
└── voice-inbox.json    待插入输入框的文字（有新版本 = 识别成功）
```

录音时每 120 ms 读一次 `input.wav` 末尾 100 ms（3200 字节 @ 16 kHz 单声道 s16），
算 RMS 转 dBFS，映射到 0..1 后画成 `▁▂▃▄▅▆▇█` 八个方块，再通过
`qs ipc ... osd show` 推给 Omarchy shell 的 OSD（`duration=0` 表示不自动收起）。

- 源码：`voice-osd/`（Rust，**纯 std 零依赖**，离线可编译）
- 安装方式：有 `cargo` 就**从源码编译**；没有就下载
  [GitHub Actions](.github/workflows/release.yml) 在打 tag 时编译好的预编译二进制
- 开机自启：`~/.config/systemd/user/wetypex-voice-osd.service`

### 8. 状态栏插件（可选）

Omarchy 社区插件 `unseencurtain.languages` 的输入法列表是**写死**的，只有
`keyboard-us` 和 `pinyin`。装了微信输入法之后 `activeIndex` 匹配不到，会回落到 0，
于是状态栏永远显示 "EN"，下拉里的 "Chinese" 还会去执行 `fcitx5-remote -s pinyin`
（根本没装）。脚本会把它改成 `keyboard-us + wetypex`（有 rime 就再加 rime）。

---

## 踩坑记录

这些都是实际排查出来的，写下来省得别人再踩。

### 1. Shift 切不了中英文 —— 键名被 `ALPHABETIC` 改掉了

**症状**：按住 Shift 完全没反应。把 Shift 配成 fcitx5 的 TriggerKey 也没用。

**根因**：Omarchy 默认的 `kb_options` 里有 `shift:both_capslock_cancel`
（因为 Omarchy 把 CapsLock 键设成了 Compose，需要给 CapsLock 找个别的地方）。
这个选项在 xkeyboard-config 里是：

```c
// /usr/share/X11/xkb/symbols/shift
xkb_symbols "lshift_both_capslock_cancel" {
    key <LFSH> {[  Shift_L,  Caps_Lock  ], type[group1]="ALPHABETIC" };
};
```

`ALPHABETIC` 类型在 **Shift 修饰位生效时选第 2 级**，所以 Shift 的**松开**事件
（那一刻 Shift 修饰位还在）算出来的键名是 `Caps_Lock` 而不是 `Shift_L`。
fcitx5 的调试日志能直接看到：

```
Shift_L          IsRelease=0     ← 按下：还没有 Shift 修饰位 → 第 1 级 → Shift_L
Shift+Caps_Lock  IsRelease=1     ← 松开：Shift 修饰位还在   → 第 2 级 → Caps_Lock
```

而 fcitx5 / WeTypeX 判断「同一个修饰键按下再松开」要求两次键名一致：

```cpp
// WeTypeX src/plugin/wetype.cpp
if (s->modifierCandidate == sym && ((shiftModifier && *shiftSwitch) || ...))
```

```cpp
// fcitx5 src/lib/fcitx-utils/key.cpp
bool Key::isReleaseOfModifier(const Key &key) const {
    if (!key.isModifier()) return false;
    ...
}
```

**处理**：从 `kb_options` 里去掉 `shift:both_capslock_cancel`。

### 2. Fn 键完全收不到 —— keyd 的虚拟键盘没声明 `KEY_FN`

**根因**：系统装了 keyd（键盘重映射守护进程），它**抓走物理键盘再通过自己的虚拟键盘转发**。
但 keyd 的虚拟键盘没有声明 `KEY_FN`（内核里 `KEY_FN = 464`）：

```bash
# 物理键盘支持 Fn
$ cat /sys/class/input/event4/device/capabilities/key
... fffffffffffffffe            # 第 8 个字（bit 448-511）里 bit 464 是 1

# keyd 的虚拟键盘不支持
$ cat /sys/class/input/event14/device/capabilities/key
10000000000000 0 ffffffffffffff0f ...   # 只有 6 个字，最多到 bit 383
```

而 **libinput 会直接丢弃设备未声明过的按键**，所以 Fn 到不了 Hyprland / fcitx5：

```bash
$ sudo keyd monitor
keyd virtual keyboard   fn down      # keyd 看得到
keyd virtual keyboard   fn up
$ journalctl --user -u omarchy-fcitx5 | grep IsRelease   # fcitx5 什么都收不到
```

另外 fcitx5 的「按住说话」在松手时用 `isReleaseOfModifier()`，要求这个键**必须是修饰键**，
而 fcitx5 只认 Ctrl/Alt/Shift/Super/Meta/Hyper，`Fn` 不在其中 —— 所以即使能收到也配不进去。

**处理**：用 keyd 把 Fn 映射成右 Ctrl（`KEY_RIGHTCTRL` 在虚拟键盘的声明范围内），
再把 WeTypeX 的 `voice_hold_key` 设成 `Control_R`。

```bash
$ sudo keyd monitor
keyd virtual keyboard   rightcontrol down    ← 映射生效
```

### 3. `Ctrl+Win+Shift` 换个顺序就失效 —— fcitx5 只容忍"最后按的那个键"

**根因**：fcitx5 的按键匹配：

```cpp
// src/lib/fcitx-utils/key.cpp
bool Key::check(const Key &key) const {
    ...
    if (isModifier()) {                       // 当这个键本身是修饰键时
        Key keyAlt = *this;
        auto states = states_ & (~keySymToStates(sym_));   // 容忍“自己这个修饰位”有或没有
        keyAlt.states_ |= keySymToStates(sym_);
        return (key.sym_ == sym_ && key.states_ == states) ||
               (key.sym_ == keyAlt.sym_ && key.states_ == keyAlt.states_);
    }
```

它只对**最后按下的那个键**放宽，其它修饰位必须严格相等。所以配了
`Control+Super+Shift_L` 之后：

| 按键顺序 | 最后按下 | 是否匹配 |
| --- | --- | --- |
| Win → Ctrl → **Shift** | Shift | ✅ |
| Ctrl → Shift → **Win** | Win | ❌ 配置里要求 Shift |
| Shift → Win → **Ctrl** | Ctrl | ❌ |

**处理**：把 3 种组合都写进 `voice_launch_key`（修饰键在集合里无序，3 条覆盖全部 6 种顺序）：

```
Control+Super+Shift_L, Control+Shift+Super_L, Super+Shift+Control_L
```

### 4. 识别成功但文字插不进输入框 —— 队列版本号被写超前了

**根因**：`voice-inbox.json` 的 `version` 是**纳秒时间戳**，插件只接受**比上次更大**的：

```cpp
// WeTypeX src/plugin/wetype.cpp  receiveVoice()
if (!version || version <= lastVoiceVersion_ || text.empty())
    return;
```

只要有**任何一个**写入者写了超前的版本号（例如手动测试时写了个未来的时间戳），
之后所有真实识别结果都会被永久丢弃 —— 直到系统时间追上那个值。

**处理**：改配置/测试时不要写未来的 `version`；真遇到了就重启 fcitx5 重置
`lastVoiceVersion_`。本仓库的浮窗程序只读不写这个文件。

### 5. 按下快捷键没有任何提示 —— WeTypeX 压根没有语音 UI

**根因**：翻遍 `src/plugin/wetype.cpp`，`voiceRecording_` 只用来做逻辑判断，
整个 `keyEvent()` / `panel()` 里没有一行和语音相关的界面代码：

```cpp
bool voiceRecording_ = false, voiceHold_ = false;   // 只有逻辑，没有 UI
```

所以按下快捷键后屏幕不会有任何变化，用户根本无法判断是否在录音 —— 这也是
「按了没反应」这类反馈的主要来源。

**处理**：本仓库的浮窗程序（见[第 7 条](#7-音量波形浮窗本仓库自己写的)）。

### 6. 顺带一提：DBus 名字抢占

Omarchy 把 fcitx5 做成 `Type=dbus` 的 systemd 用户服务。当服务不在运行、而某个客户端
（状态栏、输入法切换器）请求 `org.fcitx.Fcitx5` 时，session bus 会按
`/usr/share/dbus-1/services/org.fcitx.Fcitx5.service` 直接拉一个**游离实例**，
和 systemd 服务互相抢名字，导致插件反复加载/卸载、输入法列表被清空。

脚本在重启 fcitx5 时做了重试（清掉游离实例再启动），平时只要服务活着就不会有问题。

---

## 手动安装（非 Arch 系统）

Debian / Ubuntu / Fedora 请先按上游 README 用官方 `.deb` / `.rpm` 装好 `fcitx5-wetypex`，
然后手动做这几步（和脚本里的一致）：

```bash
# 1) 官方运行时
fcitx5-wetypex-setup --download --accept-upstream-license

# 2) WeTypeX 配置：往 ~/.config/fcitx5/wetypex.json 里加（保留已有项）
#    见“它到底改了什么”第 3 条

# 3) 输入法列表：把 wetypex 加进 ~/.config/fcitx5/profile 的 [Groups/0/Items/N]
#    注意先停 fcitx5 再改，改完重启

# 4) 键盘（Hyprland）：去掉 kb_options 里的 shift:both_capslock_cancel

# 5) Fn 按住说话（可选）
sudo pacman -S keyd 2>/dev/null || sudo apt install keyd
# 在 /etc/keyd/default.conf 里加 fn = rightcontrol，然后重启 keyd

# 6) 浮窗提示（二选一）
#    a. 有 Rust 工具链：从源码编译
cd voice-osd && cargo build --release
install -m755 target/release/wetypex-voice-osd ~/.local/bin/
#    b. 没有 Rust：下载 CI 编译好的
#       https://github.com/vst93/wetypex-setup/releases/latest
#       → wetypex-voice-osd-x86_64

install -Dm644 ../files/wetypex-voice-osd.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now wetypex-voice-osd
```

> 非 Hyprland 的 Wayland 合成器（sway / niri 等）：第 4 步改成在你自己的输入配置里
> 去掉 `shift:both_capslock_cancel`（sway 是 `input "type:keyboard" xkb_options ...`）。

---

## 排错

```bash
# 官方运行时是否就绪（core_ready 应为 true）
fcitx5-wetypex-setup --check

# 输入法有没有注册上
fcitx5-remote -m wetypex          # 应输出 wetypex
fcitx5-remote -n                  # 当前输入法
fcitx5-diagnose | less

# 浮窗服务
systemctl --user status wetypex-voice-osd
journalctl --user -u wetypex-voice-osd -n 50

# 键盘选项是否还有那个坑（应输出不含 shift:both_capslock_cancel 的值）
hyprctl getoption input:kb_options

# Fn 有没有映射成功（按 Fn 应看到 rightcontrol down）
sudo keyd monitor
```

**常见症状对照：**

| 症状 | 检查 |
| --- | --- |
| 看不到 WeTypeX | `fcitx5-remote -r` 重载；`fcitx5-diagnose` 看插件搜索路径 |
| 输入核心启动失败 | `fcitx5-wetypex-setup --check`，看 `manifest.txt` / `image.macho` 在不在 |
| Shift 不切换 | `hyprctl getoption input:kb_options` 是否还含 `shift:both_capslock_cancel` |
| 按住 Fn 没反应 | `sudo keyd monitor` 按 Fn 是否输出 `rightcontrol`；`wetypex.json` 里 `voice_hold_key` 是否 `Control_R` |
| 浮窗不出现 | 服务是否 active；非 Omarchy 环境会退回 `notify-send`，确认装了 `libnotify` |
| 浮窗出现但没文字 | 看 `state/voice/result.json` 的 `ok`；`ok:false` 说明没识别到内容 |
| 识别不出内容 | 见[踩坑记录](#踩坑记录)第 4 条，以及麦克风：`pw-record --rate 48000 --channels 1 /tmp/t.wav` 录 5 秒说话，`ffmpeg -i /tmp/t.wav -af volumedetect -f null -` 看 `max_volume`（正常说话应在 -20 ~ -30 dB） |
| 状态栏一直显示 EN | 状态栏插件的输入法列表是写死的，跑 `extras/patch-statusbar-languages.py` |
| `Ctrl+Win+Shift` 没反应 | 看 `~/.config/fcitx5/wetypex.json` 里 `voice_launch_shortcut` 是不是被设置窗口关成了 `false`（改成 `true` 后重启 fcitx5） |
| 云候选 / 语音没结果 | 需要配对账户：`fcitx5-wetypex-settings` → 账户/设备 → 六位匹配码 |

---

## 卸载

```bash
./uninstall.sh            # 只撤销本脚本加的东西
./uninstall.sh --purge    # 连 fcitx5-wetypex 软件包一起删
```

用户数据（配对身份、词库、语音缓存）不会被自动删除，卸载完会提示路径。

---

## 项目结构

```
wetypex-setup/
├── install.sh                         一键安装（幂等 + 自动备份）
├── uninstall.sh                       卸载
├── .github/workflows/release.yml       打 tag 自动编译并发布浮窗二进制
├── files/
│   ├── wetypex-voice-osd.service      systemd 用户服务
│   └── keyd-default.conf              Fn → 右 Ctrl
├── voice-osd/                         浮窗提示（Rust，纯 std 零依赖）
│   ├── Cargo.toml
│   ├── README.md
│   └── src/main.rs
└── extras/
    └── patch-statusbar-languages.py   修补状态栏插件的写死列表
```

### 发布预编译二进制

```bash
git tag v1.0.0 && git push origin v1.0.0
```

GitHub Actions 会自动编译 `wetypex-voice-osd-x86_64` 并挂到 Release 上，
`install.sh` 在没有 cargo 的机器上会去取它。

---

## 原项目与致谢

### 核心项目

- **[panxuc/fcitx5-wetypex](https://github.com/panxuc/fcitx5-wetypex)（WeTypeX）** ——
  **本项目依赖的核心**，MIT 许可。
  它是一个非官方的第三方开源项目，让 Linux 能通过 fcitx5 用上微信输入法：
  从官方包里提取输入核心与词典，生成固定地址的 Linux 可加载映像；运行时用一个
  小型 Mach-O ABI 兼容宿主提供原版核心用到的 Darwin C/C++ 接口，并把网络传输接到
  Linux 的 TLS / WebSocket 实现上。输入宿主与账户命令跑在 Bubblewrap 沙箱里。
  **本仓库只是它的安装与体验补丁，没有它什么都跑不起来。**
  相关文档（本地也有副本）：
  `docs/architecture.md`、`docs/configuration.md`、`docs/feature-status.md`、
  `docs/troubleshooting.md`。

- **[fcitx/fcitx5](https://github.com/fcitx/fcitx5)** —— 输入法框架本身，LGPL-2.1+。
  本仓库大量依赖它的行为（`Key::check`、`isReleaseOfModifier`、Wayland 前端等），
  踩坑记录里的分析都基于 5.1.22 源码。

### 桌面环境

- **[Omarchy](https://omarchy.org/)** —— Arch + Hyprland 的开箱即用发行版。
  本仓库的浮窗**直接复用它的 OSD**（`omarchy-osd` / Quickshell 的 `osd` 插件），
  因此视觉风格和调音量时的浮窗完全一致。Omarchy 的默认键盘配置
  （`compose:caps,shift:both_capslock_cancel`）也是踩坑记录第 1 条的来源。
- **[Quickshell](https://quickshell.org/)** —— Omarchy shell 的底层工具包，OSD 由它渲染。
- **[Hyprland](https://hyprland.org/)** —— 合成器。键盘选项、`hyprctl` 都来自它。

### 工具

- **[keyd](https://github.com/rvaiya/keyd)** —— 键盘重映射守护进程，本仓库用它把 Fn
  映射成右 Ctrl（踩坑记录第 2 条）。
- **[unseencurtain.languages](https://github.com/unseencurtain/omarchy-plugins)** ——
  Omarchy 的社区状态栏插件，用来显示/切换输入法。它的输入法列表是写死的，
  本仓库提供了 `extras/patch-statusbar-languages.py` 来修补。
- **PipeWire / FFmpeg / libnotify / Bubblewrap / Qt 6 / libc++** —— WeTypeX 的运行时依赖。

### 上游

- **微信输入法（WeType）/ 腾讯** —— 输入核心、词典、模型、界面资源、服务与商标归
  腾讯公司所有。WeTypeX 与本仓库都**不包含**任何微信输入法的专有代码或二进制，
  用户需要自行从官方渠道获取运行时。
- **libkqueue** —— WeTypeX 内置，保留其上游许可（ISC / BSD-2-Clause）。

### 本仓库自己写的部分

- `voice-osd/`（Rust 浮窗程序）—— MIT
- `install.sh` / `uninstall.sh` / `extras/` —— MIT

---

## 许可与声明

本仓库自有代码使用 **MIT License**。

WeTypeX 是一个**非官方**的第三方开源项目，仅供个人学习交流使用，与腾讯公司无任何关联、
合作或背书关系。本项目同样如此。使用前请阅读并遵守
[WeTypeX 的声明](https://github.com/panxuc/fcitx5-wetypex#许可与声明)与微信输入法官方的
使用条款；上游协议与接口随时可能变化，本项目不保证长期可用。

**你可能需要知道的两件事：**

1. WeTypeX 可能包含微信输入法官方服务的**遥测**。
2. 语音识别、云候选、设备同步等功能会把数据发到腾讯的服务器，并且需要配对账户。

---

## English summary

`wetypex-setup` installs the unofficial
[WeTypeX](https://github.com/panxuc/fcitx5-wetypex) (WeChat input method for Linux)
on Arch/Omarchy + Hyprland and fixes the rough edges:

1. **Shift doesn't switch languages** — Omarchy's `shift:both_capslock_cancel` xkb option
   makes the Shift *release* event resolve to `Caps_Lock`, so fcitx5 can never match
   "same modifier pressed and released". The installer strips that option.
2. **Fn key is invisible** — keyd's virtual keyboard does not declare `KEY_FN`, so
   libinput drops it. The installer remaps `fn = rightcontrol` via keyd and sets
   WeTypeX's `voice_hold_key` to `Control_R` (hold Fn to talk).
3. **`Ctrl+Win+Shift` is order-sensitive** — fcitx5's `Key::check` only relaxes the
   *last* pressed modifier. Three key entries cover all six press orders.
4. **No recording UI at all** — WeTypeX has none; `voice-osd/` (Rust, std-only, zero
   deps) draws a live volume waveform in the Omarchy OSD, falling back to
   `notify-send` elsewhere.

Everything is idempotent, backs up before editing, and never overwrites your own
`kb_options` or keyd `[main]` section.
