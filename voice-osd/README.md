# wetypex-voice-osd

WeTypeX 语音输入的浮窗提示 —— 用 Omarchy 自带的 OSD 显示**实时音量波形**、识别状态和识别结果；
探测不到 Omarchy 的 OSD 时会自动退回 `notify-send` 桌面通知（无波形）。

纯 `std` 实现，**零依赖**，离线也能 `cargo build`。

## 为什么需要它

WeTypeX 插件本身没有任何录音提示界面 —— 源码里 `voiceRecording_` 只用来做逻辑判断，
整个 `keyEvent()` / `panel()` 里没有一行语音相关的 UI。所以按下语音快捷键后屏幕上
什么都不会变，用户无法判断是否在录音。

这个程序监听 WeTypeX 写下的状态文件，把状态补成一个浮窗。

## 浮窗状态

| 时机 | 浮窗 | 停留 |
| --- | --- | --- |
| 录音中 | `󰍬 ▁▃▅▇▆▄▂▃ 正在聆听…` | 一直显示到松开按键 |
| 松开后 | `󰍬 识别中…` | 最多 60 秒（兜底） |
| 识别成功 | `󰍬 ✓ 识别出的文字` | 2 秒 |
| 识别失败 | `󰍬̸ 没识别到内容` | 4 秒 |

## 原理

监听的文件（都在 `~/.local/share/fcitx5-wetypex/state/`）：

```text
voice/recording    —— 录音期间存在，结束即删除
voice/input.wav    —— pw-record 正在写的录音，用来算电平
voice/result.json  —— 识别服务返回的原始结果（ok / text）
voice-inbox.json   —— 待插入输入框的文字（有新版本 = 识别成功）
```

录音时每 120ms 读一次 `input.wav` 末尾 100ms（`3200` 字节 @ 16kHz 单声道 s16），
算 RMS 转成 dBFS，映射到 0..1 后画成 `▁▂▃▄▅▆▇█` 八个方块，再通过
`qs ipc ... osd show` 把这一行文字推给 Omarchy shell 的 OSD。

`duration = 0` 表示 OSD 不自动收起，所以录音期间浮窗一直停留。

## 构建与安装

```bash
cargo build --release
install -m 755 target/release/wetypex-voice-osd ~/.local/bin/wetypex-voice-osd
```

## 命令行

平时由 systemd 用户服务在后台跑，不需要手动启动。排查时可以用：

```bash
wetypex-voice-osd --status     # 显示后端 / 路径 / 当前录音状态 / 当前电平
wetypex-voice-osd --version
wetypex-voice-osd --help
```

`--status` 输出示例：

```text
wetypex-voice-osd 1.0.1
显示后端   : Omarchy OSD（屏幕底部浮窗，支持波形）
Omarchy    : /usr/share/omarchy/shell
录音状态   : 否
录音文件   : /home/v/.local/share/fcitx5-wetypex/state/voice/input.wav（78496 字节）
识别结果   : {"ok": true, "text": "潘森", ...}
待插入队列 : {"version": 1790539039, "text": "潘森"}
当前电平   : 0%
```

别人报“没反应”时，让他把 `--status` 的输出贴出来，就能判断卡在哪一步
（显示后端 / 录音 / 识别 / 回填）。

## 开机自启

`~/.config/systemd/user/wetypex-voice-osd.service`：

```ini
[Unit]
Description=WeTypeX 语音输入浮窗提示（音量波形 / 识别中 / 识别结果）
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStart=%h/.local/bin/wetypex-voice-osd
Restart=always
RestartSec=3

[Install]
WantedBy=graphical-session.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now wetypex-voice-osd.service
```

## 可调参数

都在 `src/main.rs` 顶部的常量里：

| 常量 | 默认 | 说明 |
| --- | --- | --- |
| `BARS` | 8 | 波形格数 |
| `TICK` | 120ms | 录音时刷新间隔（同时也是每格的时长） |
| `DB_MIN` / `DB_MAX` | -65 / -15 dBFS | 电平映射区间；麦克风偏安静就把 `DB_MIN` 再压低 |
| `TEXT_MAX` | 14 | 识别结果在浮窗里最多显示几个字 |
| `RECOGNIZING_MS` | 60000 | “识别中…” 的兜底超时 |

改完重新 `cargo build --release && install ...`，再 `systemctl --user restart wetypex-voice-osd`。
