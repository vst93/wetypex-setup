//! WeTypeX 语音输入浮窗提示（实时音量波形 + 识别状态 / 结果）
//!
//! WeTypeX 插件本身没有任何录音提示界面（源码里 `voiceRecording_` 只做逻辑判断，
//! 整个 `keyEvent()` / `panel()` 没有一行语音 UI），所以按下语音快捷键后屏幕上
//! 什么都不会变，用户无法判断是否在录音。
//!
//! 这个程序监听 WeTypeX 写下的状态文件，把状态补成提示：
//!
//! ```text
//! state/voice/recording   —— 录音期间存在，结束即删除
//! state/voice/input.wav   —— pw-record 正在写的录音（用来算电平）
//! state/voice/result.json —— 识别服务返回的原始结果（ok / text）
//! state/voice-inbox.json  —— 待插入输入框的文字（有新版本 = 识别成功）
//! ```
//!
//! 两种显示后端，启动时自动探测：
//!
//! * **Omarchy OSD**（优先）：屏幕底部居中的圆角浮窗，支持实时波形
//! * **notify-send**（兜底）：普通桌面通知，只显示状态变化
//!
//! 录音时按 100ms 一帧读取 wav 末尾，算 RMS 转 dBFS，画成 `▁▂▃▄▅▆▇█` 八个方块。
//! OSD 的 `duration = 0` 表示不自动收起，所以录音期间浮窗一直停留。
//!
//! 纯 `std` 实现，零依赖。

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::Duration;

// ── 可调参数 ────────────────────────────────────────────────────────────────

/// 波形格数
const BARS: usize = 8;
/// 波形用的方块字符（U+2581..U+2588）
const GLYPHS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
/// 每帧读取的字节数：100ms @ 16kHz 单声道 s16
const FRAME_BYTES: u64 = 3200;
/// 录音时的刷新间隔（同时也是每格代表的时长）
const TICK: Duration = Duration::from_millis(120);
/// 空闲时的轮询间隔
const IDLE: Duration = Duration::from_millis(100);
/// 电平映射区间（dBFS）。麦克风偏安静就把 DB_MIN 再压低。
const DB_MIN: f64 = -65.0;
const DB_MAX: f64 = -15.0;
/// 识别结果在提示里最多显示几个字
const TEXT_MAX: usize = 14;
/// “识别中…” 的兜底超时（毫秒）
const RECOGNIZING_MS: u64 = 60_000;
/// notify-send 兜底模式使用的通知替换 ID
const NOTIFY_ID: &str = "9001";

// ── 路径 ────────────────────────────────────────────────────────────────────

struct Paths {
    recording: PathBuf,
    wav: PathBuf,
    result: PathBuf,
    inbox: PathBuf,
    shell: PathBuf,
}

impl Paths {
    fn discover() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home".into());
        let data =
            std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| format!("{home}/.local/share"));
        let state = Path::new(&data).join("fcitx5-wetypex").join("state");
        let omarchy =
            std::env::var("OMARCHY_PATH").unwrap_or_else(|_| "/usr/share/omarchy".into());
        Paths {
            recording: state.join("voice").join("recording"),
            wav: state.join("voice").join("input.wav"),
            result: state.join("voice").join("result.json"),
            inbox: state.join("voice-inbox.json"),
            shell: Path::new(&omarchy).join("shell"),
        }
    }
}

// ── 显示后端 ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum Ui {
    /// Omarchy 的 OSD（支持实时波形）
    Osd,
    /// 普通桌面通知（兜底）
    Notify,
}

impl Ui {
    /// 探测 Omarchy shell 的 OSD 是否可用。
    fn detect(shell: &Path) -> Self {
        let alive = Command::new("qs")
            .args(["ipc", "-n", "-p"])
            .arg(shell)
            .args(["call", "--", "osd", "ping"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if alive {
            Ui::Osd
        } else {
            Ui::Notify
        }
    }

    /// 显示一条提示。`duration_ms == 0` 表示不自动收起（仅 OSD 支持）。
    fn show(self, shell: &Path, icon: &str, message: &str, duration_ms: u64, urgent: bool) {
        match self {
            Ui::Osd => osd_show(shell, icon, message, duration_ms),
            Ui::Notify => notify_show(icon, message, duration_ms, urgent),
        }
    }
}

/// 最小 JSON 字符串转义（我们只往里塞自己的文本）。
fn json_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// 通过 Omarchy shell 的 IPC 显示 OSD。
fn osd_show(shell: &Path, icon: &str, message: &str, duration_ms: u64) {
    let payload = format!(
        "{{\"icon\":\"{}\",\"message\":\"{}\",\"value\":\"\",\"progressText\":\"\",\
          \"max\":\"100\",\"duration\":\"{}\"}}",
        json_escape(icon),
        json_escape(message),
        duration_ms
    );
    let _ = Command::new("qs")
        .args(["ipc", "-n", "-p"])
        .arg(shell)
        .args(["call", "--", "osd", "show"])
        .arg(payload)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// 把 OSD 用的图标名映射到图标主题里的名字（notify-send 用）。
fn theme_icon(icon: &str) -> &'static str {
    match icon {
        "microphone-muted" => "microphone-sensitivity-muted",
        _ => "audio-input-microphone",
    }
}

/// 用 notify-send 显示桌面通知（非 Omarchy 环境的兜底）。
fn notify_show(icon: &str, message: &str, duration_ms: u64, urgent: bool) {
    let mut cmd = Command::new("notify-send");
    cmd.args(["-r", NOTIFY_ID, "-a", "WeTypeX 语音", "-i", theme_icon(icon)])
        .args(["-t", &duration_ms.to_string()])
        .args(["-u", if urgent { "critical" } else { "normal" }])
        .arg("WeTypeX 语音")
        .arg(message)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let _ = cmd.status();
}

// ── 电平计算 ────────────────────────────────────────────────────────────────

/// 读取录音文件末尾一小段，返回 0..1 的电平。
fn level(wav: &Path) -> f64 {
    let Ok(meta) = fs::metadata(wav) else {
        return 0.0;
    };
    let size = meta.len();
    if size <= 44 {
        return 0.0; // 只有 wav 头
    }
    let start = std::cmp::max(44, size.saturating_sub(FRAME_BYTES));
    let Ok(mut file) = File::open(wav) else {
        return 0.0;
    };
    if file.seek(SeekFrom::Start(start)).is_err() {
        return 0.0;
    }
    let mut buf = Vec::with_capacity((size - start) as usize);
    if file.take(size - start).read_to_end(&mut buf).is_err() {
        return 0.0;
    }
    let count = buf.len() / 2;
    if count == 0 {
        return 0.0;
    }
    let mut sum = 0.0f64;
    for pair in buf[..count * 2].chunks_exact(2) {
        let sample = i16::from_le_bytes([pair[0], pair[1]]) as f64;
        sum += sample * sample;
    }
    let rms = (sum / count as f64).sqrt() / 32768.0;
    let db = if rms > 0.0 { 20.0 * rms.log10() } else { -90.0 };
    ((db - DB_MIN) / (DB_MAX - DB_MIN)).clamp(0.0, 1.0)
}

fn render_wave(history: &[f64; BARS]) -> String {
    history
        .iter()
        .map(|v| GLYPHS[((v * 7.99) as usize).min(GLYPHS.len() - 1)])
        .collect()
}

// ── 极简 JSON 取值（只解析我们自己脚本写出的内容） ──────────────────────────

fn read(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok()
}

fn json_string(json: &str, key: &str) -> Option<String> {
    let pattern = format!("\"{key}\"");
    let rest = json.get(json.find(&pattern)? + pattern.len()..)?;
    let rest = rest.get(rest.find(':')? + 1..)?.trim_start();
    let mut chars = rest.strip_prefix('"')?.chars();
    let mut out = String::new();
    while let Some(ch) = chars.next() {
        match ch {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                'u' => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if let Some(c) = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                        out.push(c);
                    }
                }
                other => out.push(other),
            },
            other => out.push(other),
        }
    }
    None
}

fn json_bool(json: &str, key: &str) -> Option<bool> {
    let pattern = format!("\"{key}\"");
    let rest = json.get(json.find(&pattern)? + pattern.len()..)?;
    let rest = rest.get(rest.find(':')? + 1..)?.trim_start();
    if rest.starts_with("true") {
        Some(true)
    } else if rest.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

/// 按字符截断，超长补省略号。
fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max).collect();
    out.push('…');
    out
}

// ── 主循环 ──────────────────────────────────────────────────────────────────

fn main() {
    let paths = Paths::discover();
    let ui = Ui::detect(&paths.shell);

    let mut history = [0.0f64; BARS];
    let mut recording_prev = false;
    // 记录启动时的状态，避免把上次留下的结果当成新结果弹一次
    let mut result_prev = read(&paths.result);
    let mut inbox_prev = read(&paths.inbox);

    loop {
        if paths.recording.exists() {
            history.rotate_left(1);
            history[BARS - 1] = level(&paths.wav);

            match ui {
                Ui::Osd => {
                    let wave = render_wave(&history);
                    ui.show(&paths.shell, "microphone", &format!("{wave} 正在聆听…"), 0, false);
                }
                // 通知模式不刷波形（会变成通知轰炸），只在开始录音时提示一次
                Ui::Notify => {
                    if !recording_prev {
                        ui.show(
                            &paths.shell,
                            "microphone",
                            "🎤 正在聆听…（松开结束）",
                            0,
                            false,
                        );
                    }
                }
            }

            recording_prev = true;
            sleep(TICK);
            continue;
        }

        if recording_prev {
            // 刚松开：进入识别，给个兜底超时（万一服务没回包也会自己收起）
            history = [0.0; BARS];
            ui.show(&paths.shell, "microphone", "识别中…", RECOGNIZING_MS, false);
            recording_prev = false;
            result_prev = read(&paths.result);
            inbox_prev = read(&paths.inbox);
            sleep(IDLE);
            continue;
        }

        if let Some(current) = read(&paths.result) {
            if result_prev.as_deref() != Some(current.as_str()) {
                result_prev = Some(current.clone());
                if json_bool(&current, "ok") == Some(false) {
                    ui.show(
                        &paths.shell,
                        "microphone-muted",
                        "⚠️ 没识别到内容",
                        4_000,
                        true,
                    );
                }
            }
        }

        if let Some(current) = read(&paths.inbox) {
            if inbox_prev.as_deref() != Some(current.as_str()) {
                inbox_prev = Some(current.clone());
                if let Some(text) = json_string(&current, "text") {
                    let text = truncate(text.trim(), TEXT_MAX);
                    if !text.is_empty() {
                        ui.show(&paths.shell, "microphone", &format!("✓ {text}"), 2_000, false);
                    }
                }
            }
        }

        sleep(IDLE);
    }
}
