#!/usr/bin/env python3
"""修补状态栏的输入法插件，让它认识 wetypex。

Omarchy 社区插件 `unseencurtain.languages` 的输入法列表是**写死**的，
默认只有 keyboard-us 和 pinyin。装了微信输入法之后：

    activeIndex 找不到 wetypex -> 回落到 0 -> 永远显示 "EN"
    下拉里的 "Chinese" 会执行 `fcitx5-remote -s pinyin`，而 pinyin 根本没装

所以状态栏显示永远是错的。这个脚本把 languages 数组替换成
keyboard-us + wetypex（可选再加 rime），并修正 lastIm 的默认值。

用法：
    patch-statusbar-languages.py <Panel.qml> [--with-rime]
"""

import argparse
import pathlib
import re
import shutil
import sys
import time

ENTRIES = {
    "keyboard-us": '    { im: "keyboard-us", short: "EN", name: "English", detail: "US keyboard" }',
    "wetypex": '    { im: "wetypex", short: "微", name: "WeTypeX", detail: "微信输入法" }',
    "rime": '    { im: "rime", short: "rime", name: "Rime", detail: "中州韵" }',
}

ARRAY_RE = re.compile(
    r"readonly property var languages:\s*\[.*?\n\s*\]", re.DOTALL
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("panel", type=pathlib.Path)
    parser.add_argument("--with-rime", action="store_true")
    args = parser.parse_args()

    panel: pathlib.Path = args.panel
    if not panel.is_file():
        print(f"跳过：找不到 {panel}", file=sys.stderr)
        return 0

    source = panel.read_text(encoding="utf-8")
    wanted = ["keyboard-us", "wetypex"] + (["rime"] if args.with_rime else [])
    replacement = (
        "readonly property var languages: [\n"
        + ",\n".join(ENTRIES[name] for name in wanted)
        + "\n  ]"
    )

    if not ARRAY_RE.search(source):
        print("跳过：没找到 languages 数组（插件版本可能变了）", file=sys.stderr)
        return 1

    if 'im: "wetypex"' in source:
        print("已经包含 wetypex，无需修改")
        return 0

    backup = panel.with_suffix(f".qml.bak.{time.strftime('%Y%m%d%H%M%S')}")
    shutil.copy2(panel, backup)

    updated = ARRAY_RE.sub(replacement, source, count=1)
    # lastIm 的默认值原本是 "pinyin"，指向一个不存在的输入法
    updated = updated.replace('property string lastIm: "pinyin"', 'property string lastIm: "wetypex"')
    updated = updated.replace("printf 'pinyin'", "printf 'wetypex'")
    panel.write_text(updated, encoding="utf-8")

    print(f"已修补 {panel}（备份：{backup.name}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
