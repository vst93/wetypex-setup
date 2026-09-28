#!/usr/bin/env python3
"""给 WeTypeX 的语音脚本打「松手后补录」的补丁。

背景
----
`/usr/bin/fcitx5-wetypex-voice` 的 `stop` 分支会**立刻** kill 掉 pw-record：

    kill -INT "$recorder" 2>/dev/null || true

但人说话时往往在松开按键之后才把最后一个字说完（尤其是中文的尾音），
于是末尾一两个字总是识别不出来。按住的这段时间里最后的收音全丢了。

做法
----
在 `kill -INT` 之前插入一小段 sleep，让录音多跑一会儿再收尾。

补录时长（秒）可以在下面这个文件里改，默认 1：

    ~/.config/wetypex-setup/voice-tail      # 写个数字，比如 1.5；写 0 关闭

用法
----
    wetypex-patch-voice-tail [目标脚本]

不传参数就补 `/usr/bin/fcitx5-wetypex-voice`。
可以用 `--revert` 撤销，`--check` 只检查状态。

脚本本身带标记注释，重复执行安全；被 pacman 升级覆盖后，
`/etc/pacman.d/hooks/wetypex-voice-tail.hook` 会自动重新打上。
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys
import time

DEFAULT_TARGET = pathlib.Path("/usr/bin/fcitx5-wetypex-voice")
BEGIN = "    # wetypex-setup: voice tail begin"
END = "    # wetypex-setup: voice tail end"

PATCH = f"""{BEGIN}
    # 松手后补录一小段，避免最后一个字的尾音被切掉。
    # 时长（秒）在 ~/.config/wetypex-setup/voice-tail 里改，默认 1；0 表示关闭。
    _wetypex_tail="$(cat "${{XDG_CONFIG_HOME:-$HOME/.config}}/wetypex-setup/voice-tail" 2>/dev/null || true)"
    case "$_wetypex_tail" in ''|*[!0-9.]*|.|*..*) _wetypex_tail=1 ;; esac
    sleep "$_wetypex_tail"
{END}
"""

# 在这行之前插入补丁
ANCHOR = 'kill -INT "$recorder"'


def is_patched(text: str) -> bool:
    return BEGIN in text and END in text


def patch(target: pathlib.Path, quiet: bool = False) -> int:
    def say(message: str) -> None:
        if not quiet:
            print(message)

    if not target.is_file():
        say(f"跳过：找不到 {target}")
        return 0

    text = target.read_text(encoding="utf-8", errors="surrogateescape")

    if is_patched(text):
        say(f"{target} 已经打过补丁，无需修改")
        return 0

    anchor_at = None
    for line in text.splitlines(keepends=True):
        if ANCHOR in line:
            anchor_at = text.index(line)
            break
    if anchor_at is None:
        say(f"跳过：{target} 里找不到锚点 {ANCHOR!r}（脚本结构可能变了）")
        return 1

    backup = target.with_name(f"{target.name}.bak.{time.strftime('%Y%m%d%H%M%S')}")
    shutil.copy2(target, backup)

    updated = text[:anchor_at] + PATCH + text[anchor_at:]
    tmp = target.with_name(f".{target.name}.tmp")
    tmp.write_text(updated, encoding="utf-8", errors="surrogateescape")
    tmp.chmod(target.stat().st_mode)
    tmp.replace(target)

    say(f"已给 {target} 打上「松手后补录」补丁（备份：{backup.name}）")
    return 0


def revert(target: pathlib.Path, quiet: bool = False) -> int:
    def say(message: str) -> None:
        if not quiet:
            print(message)

    if not target.is_file():
        say(f"跳过：找不到 {target}")
        return 0

    text = target.read_text(encoding="utf-8", errors="surrogateescape")
    if not is_patched(text):
        say(f"{target} 没有本补丁，无需撤销")
        return 0

    start = text.index(BEGIN)
    end = text.index(END) + len(END)
    # 连带后面的换行一起去掉
    while end < len(text) and text[end] == "\n":
        end += 1

    backup = target.with_name(f"{target.name}.bak.{time.strftime('%Y%m%d%H%M%S')}")
    shutil.copy2(target, backup)
    tmp = target.with_name(f".{target.name}.tmp")
    tmp.write_text(text[:start] + text[end:], encoding="utf-8", errors="surrogateescape")
    tmp.chmod(target.stat().st_mode)
    tmp.replace(target)
    say(f"已从 {target} 移除本补丁（备份：{backup.name}）")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="给 WeTypeX 语音脚本加/去「松手后补录」")
    parser.add_argument("target", nargs="?", type=pathlib.Path, default=DEFAULT_TARGET)
    parser.add_argument("--revert", action="store_true", help="撤销补丁")
    parser.add_argument("--check", action="store_true", help="只检查，不修改")
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args()

    if args.check:
        if not args.target.is_file():
            print(f"{args.target}: 不存在")
            return 1
        text = args.target.read_text(encoding="utf-8", errors="surrogateescape")
        print(f"{args.target}: {'已打补丁' if is_patched(text) else '未打补丁'}")
        return 0

    if args.revert:
        return revert(args.target, args.quiet)
    return patch(args.target, args.quiet)


if __name__ == "__main__":
    raise SystemExit(main())
