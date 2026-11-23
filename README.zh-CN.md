# WindowSnapshot（`wsnap`）

[English](README.md)

重启或更新 macOS 之前，把整台 Mac 的窗口布局存下来；之后用一条命令恢复原样。

macOS 重启后会重新打开 App，但窗口会全部堆在一个桌面上：全屏的变回普通窗口，分屏没了，
浏览器窗口跑到别的桌面。`wsnap` 会记录并重建这些内容：

- 每个窗口在**哪个桌面**、**哪块显示器**上
- 哪些窗口是**全屏**，以及全屏在调度中心里的先后顺序
- 哪两个窗口是**分屏**
- 普通窗口的**位置和大小**
- **Chrome 和 Safari**：每个窗口的标签页、当前标签页，以及它属于哪个**账户/描述文件**

> **现状：早期版本。** 目前只在一台 Mac 上运行过（macOS 27，见
> [测试环境](docs/LIMITATIONS.md#tested-on)）。请先运行 `wsnap doctor`，它会告诉你在你的
> 电脑上哪些功能可用。欢迎反馈其他机器上的结果。

## 安装

用 [Homebrew](https://brew.sh) 安装：

```sh
brew install ly2960794590-blip/tap/wsnap
```

Homebrew 会下载源码并在你的 Mac 上编译（大约一分钟），所以不会被系统当成"来源不明的程序"
拦下。需要 macOS 13 或更高版本，以及 Xcode 命令行工具（`xcode-select --install`）。

<details>
<summary>或者自己编译</summary>

```sh
git clone https://github.com/ly2960794590-blip/WindowSnapshot.git
cd WindowSnapshot
swift build -c release
cp .build/release/wsnap /usr/local/bin/    # 或 PATH 里的任意位置
```

</details>

然后检查环境：

```sh
wsnap doctor
```

需要两项权限：

- **辅助功能**：授权给你运行它的终端 App（系统设置 → 隐私与安全性 → 辅助功能），用来移动、
  缩放、分屏和全屏窗口。
- **自动化**：控制 Chrome 和 Safari，第一次使用时系统会询问。

要恢复多个桌面，需要启用调度中心的「向左移动一个空间」「向右移动一个空间」快捷键
（系统设置 → 键盘 → 键盘快捷键 → 调度中心）。用什么按键都可以，`wsnap` 会读取你的设置。

## 用法

| 命令 | 作用 |
|---|---|
| `wsnap backup` | 备份当前布局 |
| `wsnap backup --name 工作` | 起个名字保存，可以保存多套布局 |
| `wsnap restore` | 恢复最新的快照 |
| `wsnap restore 工作` | 恢复指定名字的布局或指定的快照 |
| `wsnap restore --dry-run` | 只显示会做什么，不动任何窗口 |
| `wsnap restore --yes` | 跳过 5 秒倒计时 |
| `wsnap list` | 列出所有快照 |
| `wsnap show [快照]` | 显示快照里的内容 |
| `wsnap doctor` | 检查这台 Mac 上哪些功能可用 |

恢复过程中请不要动鼠标和键盘。结束时它会列出没能完成、需要你手动处理的事。

快照是普通的 JSON 文件，保存在 `~/Library/Application Support/WindowSnapshot/snapshots/`，
里面有窗口标题和标签页网址。它们只留在你的 Mac 上，`wsnap` 不联网。

## 做不到的事

- 页面或文档里没保存的内容，以及已经过期的登录状态。
- 分屏的分隔线位置（恢复后是左右各一半）。
- 浏览器以外的 App 打开的是哪个文档：只会打开 App 并摆好窗口。
- Chrome 的标签页分组和固定标签页会变成普通标签页。

原理和完整的限制说明见 [docs/LIMITATIONS.md](docs/LIMITATIONS.md)（英文）。

## 许可证

[MIT](LICENSE)
