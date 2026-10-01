# MenuCraft

轻量的 macOS Finder 右键增强工具，整合文件操作、压缩解压、文件模板与滚动控制。

[![CI](https://github.com/czheng1108/menucraft/actions/workflows/ci.yml/badge.svg)](https://github.com/czheng1108/menucraft/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/czheng1108/menucraft)](https://github.com/czheng1108/menucraft/releases/latest)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

## 下载与安装

**[下载最新版通用 DMG](https://github.com/czheng1108/menucraft/releases/latest/download/MenuCraft-universal.dmg)**

一个安装包，同时支持 Apple Silicon（M 系列）与 Intel Mac。

[全部版本与更新说明](https://github.com/czheng1108/menucraft/releases) · [SHA-256 校验文件](https://github.com/czheng1108/menucraft/releases/latest/download/SHA256SUMS)

系统要求 **macOS 13 或更新**。当前版本 **0.5.1 / build 12**。

1. 下载通用版 DMG，将 MenuCraft.app 拖到 Applications。
2. 打开 MenuCraft，在系统设置启用其 Finder 扩展。
3. 需要滚动控制或隐藏文件快捷切换时，按提示授予辅助功能权限。

**当前公开安装包使用本地 ad-hoc 签名，尚未经过 Developer ID 签名和 Apple 公证。** 首次打开可能需要在系统设置中手动允许。具体操作、权限和卸载方法见 [安装说明](docs/INSTALL.txt)。

## 功能

- **文件操作**：复制路径、复制名称、终端与应用打开、剪切粘贴、移动复制、常用目录、最近目标和外接磁盘。
- **新建文件**：Markdown、TXT、JSON、YAML、Python、Shell 和 .gitignore；可编辑文本模板及日期、名称变量。
- **压缩解压**：创建 ZIP、7Z、TAR、TAR.GZ、TAR.BZ2、TAR.XZ、GZ、BZ2、XZ；支持 RAR/RAR5 解压及常见分卷。ZIP/7Z 支持 AES-256，7Z 可加密文件名。
- **滚动控制**：分别控制鼠标、触控板、纵向与横向反转，保留系统滚动速度，菜单栏可暂停。
- **整理工具**：解除文件夹、显示隐藏文件、批量重命名预览与最近一次名称恢复、创建桌面替身。
- **菜单设置**：动作启用、排序、主菜单或子菜单、彩色图标；设置窗口支持搜索与浅深色外观。

所有文件操作在本机执行。同名项目保留两者或跳过，不静默覆盖已有文件。密码仅用于当前归档任务，不存入配置、命令行参数或日志。

## 资源占用

常驻核心与设置界面分离。关闭最后一个设置或操作窗口后，界面进程退出，滚动与后台文件任务继续运行。

下表为 2026-10-01 在 Apple Silicon / macOS 15.6 上对 arm64 构建 0.5.1 的两次 30 秒空闲实测，包含 Finder 扩展，滚动控制开启：

| 状态 | 总物理内存占用 | 平均 CPU | 30 秒磁盘读写 |
|---|---:|---:|---:|
| 设置窗口关闭 | 20.4 MiB | 0.04% | 0 B |
| 设置窗口打开 | 69.1 MiB | 0.04% | 0 B |

CPU 的 100% 表示一个逻辑核心。设置页面、系统缓存和实际压缩任务会影响占用；这些数据不代表任务执行峰值。可用 `python3 scripts/measure-resources.py --seconds 30` 测量本机运行状态。

## 当前边界

- 模板内容为文本，不支持直接导入 Word、Excel、PSD 等二进制模板。
- GZ/BZ2/XZ 仅创建单文件归档；RAR 只解压。ZIP 加密密码限 1–99 个可打印英文字符，中文密码请选择 7Z。
- 当前解压拒绝链接归档和异常路径；同名输出自动添加序号。
- Magic Mouse 和软件平滑鼠标产生连续滚动事件，当前跟随触控板选项。
- Finder 扩展、云盘目录及辅助功能行为受 macOS 环境影响。Intel 构建和 CI 检查不代替 Intel 硬件上的完整交互验证。

## 从源码构建

需要 macOS、Xcode Command Line Tools（Swift / Clang）和 Python 3；无需完整 Xcode 或第三方 Python 包。

```sh
git clone https://github.com/czheng1108/menucraft.git
cd menucraft
./scripts/test.sh
./scripts/package.sh
```

默认生成 universal；单架构可运行：

```sh
ARCHS=arm64 ./scripts/package.sh
ARCHS=x86_64 ./scripts/package.sh
```

产物位于 `dist/`，不纳入 Git。版本来自根目录 `VERSION` 和 `BUILD_NUMBER`，构建时同步到三个应用组件。

## 项目结构

```text
Sources/       常驻核心、设置界面、Finder 扩展、文件操作与滚动引擎
Resources/     应用元数据与权限声明
Tests/         文件操作、菜单、归档、滚动与进程通信检查
ThirdParty/    第三方引擎、对应源码、许可证与来源
scripts/       构建、测试、打包、公证与资源测量
docs/          安装、实现与发布说明
.github/       CI 与标签发布工作流
```

[实现说明](docs/IMPLEMENTATION.md) · [发布流程](docs/RELEASING.md) · [Apple 公证准备](docs/NOTARIZATION.md)

## 许可证与致谢

自有代码、脚本与文档采用 [Apache License 2.0](LICENSE)。第三方组件保留各自许可，详见 [NOTICE](NOTICE) 和 [ThirdParty/README.md](ThirdParty/README.md)。

- 滚动引擎改编自 Scroll Reverser 1.9（Apache-2.0），保留原作者和修改说明。
- 官方 7zz 作为独立进程使用，保留 LGPL、BSD 与 unRAR 条款；完整对应源码随应用提供。
- RAR 测试素材来自 libarchive，保留其许可证。

MenuCraft 独立实现界面与文件操作，项目与 MouseBoost、Apple 等产品无隶属关系。
