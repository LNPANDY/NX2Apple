<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="frontend/screenshots/logo-dark.png">
  <img src="frontend/screenshots/logo-light.png" width="360" alt="NX2Apple, by nxnative">
</picture>

**你的 Switch 游戏，跑在你的 iPhone 上。**

**不是模拟器。不用命令行。一个 macOS App 点几下就把整个构建做完。**

[![Stars](https://img.shields.io/github/stars/LNPANDY/NX2Apple?style=social)](https://github.com/LNPANDY/NX2Apple/stargazers)
[![Forks](https://img.shields.io/github/forks/LNPANDY/NX2Apple?style=social)](https://github.com/LNPANDY/NX2Apple/network/members)
[![Issues](https://img.shields.io/github/issues/LNPANDY/NX2Apple)](https://github.com/LNPANDY/NX2Apple/issues)
[![License](https://img.shields.io/github/license/LNPANDY/NX2Apple)](LICENSE)
[![游戏](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FLNPANDY%2FNX2Apple%2Fmain%2Fdocs%2Fbadges%2Fgames.json)](docs/badges/games.json)
[![已验证](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FLNPANDY%2FNX2Apple%2Fmain%2Fdocs%2Fbadges%2Fverified.json)](docs/badges/verified.json)

[![English](https://img.shields.io/badge/🇺🇸_English-available-green)](README.md)
[![简体中文](https://img.shields.io/badge/🇨🇳_简体中文-当前-blue)](README.zh-CN.md)

<img src="frontend/screenshots/hero-features.png" width="100%" alt="NX2Apple — Switch 游戏装进 iPhone 和 Mac">

#### 🆕 最近重点更新

- **全新 GUI**：Mac 端启动器来临，像管理 Switch 一样管理你的游戏库
- **存档自由**：Mac 端各游戏存档及日志在游戏库文件夹统一管理
- **iPhone 端游戏自由**：iOS 端终于可将游戏资源 .img 文件放在移动硬盘中加载

一个 macOS App 拿你自己导出的游戏文件，点几下就把整件事做完——解包、为 Apple 芯片重写游戏代码、把
shader 翻译成 Metal、打包出装得进手机的瘦身 IPA 和分片 RomFS 归档（16 GB 的大作也装得上），最后告诉
你装上设备的三步。

**English readers** — the [English README](README.md) covers everything.

**原名 `nxnative-romfs-archive`** —— 旧链接会自动跳转到这里。

</div>

---

## 这是什么

本仓库是 **[nxnative](https://github.com/seedds/nxnative)** 的社区 fork——NSO 重写器、Horizon 宿主层、
NVN-on-Metal、各游戏的 profile 都是上游的工作，本 fork 自动跟随上游。在此之上它增加了：

- **给普通用户的图形界面。** [nxnative for Mac](frontend/README.md) 把游戏库和构建工具放在一个窗口里：
  选好游戏文件夹，选择「这台 Mac」或「iPhone / iPad」，构建过程按脚本自己的计数实时显示进度。构建好的
  Mac 游戏带着 eShop 封面出现在游戏库里，点 **Play** 即可启动，并可为每个游戏设置启动选项（与 iPhone
  启动器相同：帧率、主机模式、超分辨率等）。设备依赖自动检测并一键安装；界面跟随系统语言显示中文或英文。
  **它还会替你下载仓库、并自己更新自己**——完全不需要懂 git。
- **RomFS 归档。** 《王国之泪》的 304,243 个文件变成 127 个分片——这就是 iOS 从
  `PackageExtractionFailed` 安装失败到安装成功之间的差别（细节见下）。
- **⏸️ 构建中断可续。** 解包、DLC、模块改写和 shader 编译都会保留复用：失败或中途停止的构建从上次
  继续，参数没变的重新构建直接复用一切。
- **自动跟随上游。** 每天一次的 GitHub Actions 把本 fork 的特性重新应用到 upstream 新树，验证
  （脚本解析、归档读取测试、macOS 宿主编译）后推送——补丁对不上时开 issue 附日志，不推送。
- **79 个游戏 profile**，每个游戏需要的更新包版本单独列出。三个在本 fork 完整验证；44 个上游
  报告 iPhone 可玩。

---

## 目录

- [功能一览](#功能一览)
- [快速开始](#快速开始)
- [支持的游戏](#支持的游戏)——完整列表；[实测](#实测游戏)在前
- [工作原理](#工作原理)
- [更新历史](#更新历史)
- [参与贡献：着色器与新游戏](#参与贡献着色器与新游戏)
- [限制](#限制)
- [致谢](#致谢)
- [法律](#法律)

---

## 功能一览

| 功能 | 说明 |
|---|---|
| **一键构建** | 选好文件，按一下构建。全程不用命令行 |
| **RomFS 归档** | 30 万文件 → 约 100 个分片，16 GB 的大作也装得上 |
| **断点续传** | 中断的构建接着跑；没变的部分直接复用 |
| **79 个游戏 profile** | 每个都标注它需要的精确更新版本 |
| **安装引导** | 装到手机的三步，带「在访达中显示」 |
| **中英双语** | 跟随设备语言，标题栏随时切换 |
| **自助安装** | 自动下载仓库，App 自己也能更新自己 |
| **自动同步上游** | 每天一次，带验证；补丁失效会开 issue |

---

## 快速开始

1. **下载 App** —— [最新版本](https://github.com/LNPANDY/NX2Apple/releases/latest)
   （`NS-Port-Builder-macOS-arm64.zip`）。解压，首次启动右键 → 打开。
2. **让它把项目取回来** —— 仓库分组里有「下载仓库」按钮（浅克隆到 `~/NX2Apple`）。GitHub 不顺手？
   面板上有手动 ZIP 的路线。
3. **选好游戏文件** —— 本体、更新包、DLC 和 `prod.keys`，分开选或一个文件夹全选。
4. **按构建**，然后照它给出的三步装到手机。

> 环境要求：Apple Silicon Mac + macOS 26.6+、装了 iOS SDK 的 [Xcode](https://apps.apple.com/app/xcode/id497799835) 27.1、Python 3.9+、.NET SDK 10。
> App 的依赖面板会逐项检测，能装的直接装。游戏文件和 `prod.keys` 需要你自己的——本仓库不含任何数据。

---

## 实测游戏

**3 款在本 fork 完整验证**（构建 → 安装 → 真机可玩）、**29 款上游报告可玩**、**共 58 个 profile**。
每款游戏需要的精确更新版本见[完整表格](#支持的游戏)。

| 游戏 | 本 fork 验证 | 备注 |
|---|---|---|
| **塞尔达传说：王国之泪** | ✅ | 304,243 个文件 → 127 片，逐字节校验 |
| **Hades II** | ✅ | 33 个文件的归档 |
| **集合啦！动物森友会** | ✅ | 103,645 个文件 → 72 片，流畅运行 |

---

## 工作原理

### 图形界面

`frontend/` 是一个 macOS App，用窗口代替终端完成下面的第 2–5 步，给不想读构建日志的人用：四项输入
分开选（本体、更新、DLC、`prod.keys`）、依赖面板检测并安装缺的东西、脚本真实的阶段列表和实时百分比、
结束时产出归档分片。

<details>
<summary><b>问题、解法与归档格式（点开）</b></summary>

```bash
cd frontend && swift run          # 或双击 frontend/nxnative.app
```

界面双语：跟随系统语言（任何中文变体显示中文，**其他一律英文**）。

它跑的脚本和命令行完全相同，所以下面的一切同样适用；详见 [frontend/README.md](frontend/README.md)。
预编译的 App 和中英双语的发布说明（含哪些游戏已验证）在
[releases 页面](https://github.com/LNPANDY/NX2Apple/releases) 和
[docs/RELEASE_NOTES.md](docs/RELEASE_NOTES.md)。

</details>

### 问题

《王国之泪》这样的 RomFS 是 **304,243 个文件 / 15.9 GiB**。这会带来两个故障：

- **IPA 装不上。** 一个 16.6 GB、含 372,660 个条目的包在 iOS 上直接失败，报
  `PackageExtractionFailed (Could not extract archive)`。安装守护进程的解压器放弃了 ——
  单个目录里有 75,941 个文件，ZIP64 中央目录的偏移从 17.8 GB 开始。
- **把目录树拷进手机要几小时。** 「文件」App 和 Finder 都是每个文件一次往返。30 万个小文件
  还会额外产生约 1 GB 的文件系统块开销。

把目录树打成约 100 个分片文件可以同时解决两者：包保持很小，游戏文件作为一个大文件夹一次拷完。

<details>
<summary><b>归档格式（点开）</b></summary>

### 做法

一种 **ROMFSARC** 归档：一个索引文件加 N 个分片文件。

```
romfs.idx        28 MB   头部、名称池、文件表、目录表
romfs.00 ... .125        126 个分片，每片 200 MiB，源文件字节原样
```

在《王国之泪》（v1.0.0 + 1.4.3）上的实测：

| | 原始 RomFS | ROMFSARC |
|---|---|---|
| 文件数 | 304,243 | **127** |
| 最大的目录 | 75,941 个条目 | 126 个分片，均不超过 200 MiB |
| 含游戏的 IPA | 16.6 GB（装不上） | — |
| 瘦身 IPA（默认，不含 RomFS） | — | **743 MB，可安装** |
| 拷到手机 | 数小时 | 一个含 127 个文件的文件夹 |

路径查找是对排序后的文件表做二分查找；目录枚举只遍历一段连续的子项区间。索引用 `mmap` 映射，
分片按需打开，读取直接在分片上 `pread`，所以页缓存照常生效。

</details>

## 图形界面

`frontend/` 是一个 macOS App，用窗口代替终端完成下面第 2–5 步，给不想读构建日志的人用：带封面的游戏库；
构建页（选一个游戏文件夹，或分别选本体、更新包、DLC 和 `prod.keys`；目标为 Mac 或 iPhone）；直接显示
脚本自己的阶段列表、实时计数和剩余时间；Mac 版游戏的启动选项；以及自动检测并一键安装缺失依赖的设置页。

<img src="frontend/screenshots/launcher-library.webp" width="100%" alt="nxnative for Mac：游戏库，正在构建">

<details>
<summary>构建页与启动选项</summary>

<img src="frontend/screenshots/launcher-build.webp" width="66%" alt="构建游戏"> <img src="frontend/screenshots/launcher-launch-options.webp" width="32%" alt="启动选项">

</details>

```bash
cd frontend && swift run          # 或直接双击 frontend/nxnative.app
```

界面支持中英双语：跟随系统语言（中文系统用中文，**其他所有语言都用英文**）。

它调用的就是命令行那套脚本，下面的说明全部适用；细节见
[frontend/README.md](frontend/README.md)。打包好的 App 和英中双语发布说明（含已验证游戏清单）在
[Releases 页面](https://github.com/LNPANDY/NX2Apple/releases)，仓库内也存了一份：
[docs/RELEASE_NOTES.md](docs/RELEASE_NOTES.md)。

## 更新历史

最新在上。本 fork 每天跟随上游，标「同步上游」的条目是自动来的。

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-10-27 | v0.4.9 | **游戏库跟着文件夹走**：Mac 游戏的存档和日志放在 .app 旁边，首次运行自动从 `~/Library` 迁移；**iPhone 的游戏数据可以放任何位置**（Files 应用选择器，自动记住）；**追踪器八项需求全部落地**（#77–#84：密钥预检、文件拖拽、构建通知、旧工具标记、空间回收、Mac 与设备存档互拷、复制诊断报告、手柄布局）；Windows：中文界面修复、中文用户名下 Metal 探针正常、依赖安装失败闪退修复、Vulkan SDK 自动识别 |
| 2026-10-27 | v0.4.8 | **Mac 启动器真正可用了**：把 iPhone 版装到配对设备（#28）、手柄导航整个启动器（#56）、启动选项分基础/高级（#54）并加上显示模式与真实像素的 Render scale（#55）、Mods 区走 `DM_ROMFS_OVERLAY`（#57）、键位与手柄按钮可自定义（#39）；**启动时自动更新构建工具**（#60），**新版本会先说明改了什么**再让你决定；修复：每一款游戏的每一次重写都会崩（`patch_nso.py` 的 `TEXT_LO` 先用后定义，#59）、Mac 版建什么都报「需要 Python 3.12」（#53）、一个文件夹多款游戏时一款都建不了（#58）、构建失败指向窗口外的日志（#52）、Windows 中文系统显示英文界面、CI 建不了 issue |
| 2026-10-27 | v0.4.7 | **79 个游戏 profile**（+7：歧路旅人、大金刚国度 归乡 HD、大金刚国度 热带冻结）来自每日同步；**一个宿主二进制适配任意游戏的内存布局**（运行时 profile——为通用启动器打下的地基，启动器本身尚未开始）；**语言切换现在翻译整个界面**；**Xcode Beta 也算数**（检测改问 xcode-select）；上游更新导致 shader 缓存失效时会醒目提示；「输出目录」同时是构建缓存的位置已写明；Windows 前端：App 内装 Python 3.12、SDK 克隆突破 Windows 路径长度限制、LLVM 用试编译而不是 --version 验证、不再弹黑色命令行窗口；外置 exFAT 工作目录重建不再崩溃 |
| 2026-10-26 | v0.4.6 | **Windows 版按真机反馈修好**：.NET SDK 那一行以前根本不存在（所以永远装不上）、不再弹出黑色命令行窗口抢走焦点、下载走镜像并用测速挑最快的一个（真机上 LLVM 曾下 974 秒）、工具装到 App 目录外所以更新不再把它删掉、检查更新会说明 git 在做什么 |
| 2026-10-26 | v0.4.5 | **可输出 Mac App**（同一次构建产出可双击运行的 .app）；**支持 A15 / A16 及更早设备**（CPU 解压 BC 纹理，App 内开关）；每游戏独立数据目录（`Documents/games/<id>/`），外置硬盘可用；NRO 头不再被当作代码扫描；每日同步不会再静默失败 |
| 2026-10-26 | v0.4.4 | **修复了 v0.4.3 里每个 App 构建都会失败的问题**（`work` 在赋值前被读取）；72 款游戏（+3） |
| 2026-10-26 | v0.4.3 | NSZ/XCZ 压缩格式开箱可用；全新 Xcode 会明说缺 iOS SDK；三个环境陷阱关掉 |
| 2026-10-25 | v0.4.2 | App 自己下载并更新仓库、也能更新自己；58 款游戏（+10）；读档死锁修复；NuGet 报错自动恢复 |
| 2026-10-24 | v0.4.1 | 集合啦！动物森友会在 iPhone 上验证通过（103,645 文件 → 72 片）；归档打包复用未变的成果 |
| 2026-10-23 | v0.4.0 | 归档文件夹直接可拷贝并附安装引导；依赖列表可折叠；表格列出每个游戏的所需版本；更名为 NX2Apple |
| 2026-10-23 | v0.3.1 | 修复 Homebrew Python 3.15 与 `DOTNET_ROOT` 问题（#1、#2） |
| 2026-10-22 | v0.3.0 | App 图标，46 款游戏 |
| 2026-10-21 | v0.2.1 | Python 3.9 构建修复 |
| 2026-10-20 | v0.2.0 | 中英双语 |
| 2026-10-20 | v0.1.0 | 首个版本：图形界面、RomFS 归档 |

## 参与贡献：着色器与新游戏

每款新游戏都需要单独的 bring-up：profile（build ID、内存布局、纹理槽位）、必要时的 shader 读取器、
以及补丁点。**两种帮忙方式，都有用：**

- **报告一款能跑的游戏** —— 如果你让验证清单之外的游戏跑起来了，开 issue 附上 title ID、更新版本和
  你做的步骤，它会变成一个别人也能用的 profile。
- **提交缺失的着色器** —— 如果游戏能跑但首次使用某个效果时卡顿，说明它的 shader 变体不在映射表里。
  宿主可以导出找不到的部分（`DM_NVN_SHDUMP=<dir>`）；附上它们，我们把它加进 `shader_map.tsv`，
  所有人都受益。

带完整 `Documents/log.txt` 的 issue 会优先看——那份日志通常能直接指出缺的是什么。

开 issue 请用[问题表单](https://github.com/LNPANDY/NX2Apple/issues/new/choose)（游戏问题、构建问题、启动器）；需要附什么见 [CONTRIBUTING.md](CONTRIBUTING.md)（英文）。

## 跟随上游更新

引擎（`dm/`、`scripts/`、`docs/`、`ref/`、`AGENTS.md`）就是 [seedds/nxnative](https://github.com/seedds/nxnative)
在 `.upstream-ref` 所记提交上的内容，再加 [`patches/`](patches/README.md) 里的一组补丁：每项改动一个
`git format-patch` 文件，写明本 fork 为什么带着它、它在上游处于什么状态。定时的 GitHub Actions 工作流
（`.github/workflows/sync-upstream.yml`，每天 21:30 UTC，也可手动触发）用 `scripts/patches.py bump`
移动基准提交，以三方合并重新应用补丁，丢掉上游已采纳的补丁，做验证（补丁队列检查、测试、macOS
宿主编译），然后在 `sync/upstream` 分支上开一个 pull request；某个补丁对不上时，开一个点名该补丁的
issue。不会向 `main` 直接推送。`scripts/patches.py status` 列出本 fork 带着的全部补丁。

## 使用方法

### 1. 构建 App（与上游相同）

归档功能不改变正常构建流程。按上游的 [README](https://github.com/seedds/nxnative) 安装 Xcode、
Homebrew 工具和 Python 包，然后打 IPA。

```bash
git clone https://github.com/<you>/NX2Apple.git
cd NX2Apple
brew bundle --file=Brewfile                       # xcodegen, zstd, spirv-cross, glslang（打包脚本会检查它）, .NET SDK
python3 -m venv .venv                             # Homebrew 的 Python 不允许全局 pip 安装（PEP 668）
.venv/bin/python -m pip install lz4 capstone fonttools nsz "backports.zstd; python_version < '3.14'"
source .venv/bin/activate                         # 之后的 python3 即 venv 的（每个新终端都要执行）
```

`backports.zstd` 是《王国之泪》的 zstd 字典需要的；其他游戏用不到。

### 2. 你需要准备的文件

三样东西，仓库里都不带：

| 内容 | 来源 | 用途 |
|---|---|---|
| **`prod.keys`** | 从**你自己的机器**导出（见下） | 解密你的游戏 |
| **游戏的 NSP** | 从你自己的卡带或 eShop 购买记录导出 | 供解包 |
| **Xcode + iOS SDK** | App Store | 构建 App |

`prod.keys` 是主机的密钥集——一个 `名字 = 十六进制值` 格式的文本文件（约 230 条：
`master_key_xx`、`titlekek_xx`、`header_key`、`key_area_key_application_xx`……）。所有 Switch
自制软件工具都读这个格式。它**不和某个游戏绑定**：一份 `prod.keys` 能解你所有的游戏。唯一
要求是文件里包含游戏打包时代（固件世代）对应的密钥——新导出的一份覆盖所有零售游戏。

放在哪里随意，用 `-k` 传路径即可：

```bash
# 任意布局，比如
~/keys/prod.keys
# 或者就放在游戏 NSP 旁边
~/Games/Hades2/prod.keys
```

```bash
python3 scripts/build_ipa_from_nsp.py ~/Games/Hades2 -k ~/keys/prod.keys
```

密钥的导出方式在 Switch 自制软件社区有完整文档（常见做法是在破解机上跑 Lockpick_RCM）；
本仓库不涉及也不携带这一步。两条来自真实导出文件的实用提示：

- **格式错误的行。** 有的导出工具会写出十六进制值长度不对的行（真实案例：33 行长度错误的
  `master_kek_source_*`），解包工具会因此拒绝整个文件。删掉这些行，原文件留个备份。
- **更新包。** 更新 NSP 的 ticket 可能带比本体更新的密钥世代。解包工具直接从每个 NSP 内部的
  common ticket 读 title key，所以实际使用中只要 `prod.keys` 不算太旧，两份都能解开——这里
  实测过本体是世代 15、更新是世代 16，keys 文件只到 15，两个包都正常解出。

### 3. 把 RomFS 打包成归档

```bash
python3 dm/tools/romfs_arc.py pack <RomFS 目录> <输出基路径> --shard-mib 200
```

`<RomFS 目录>` 是 `nx_extract` 解出来的那个目录（里面有 `Pack/`、`Banc/`、`Sound/` 等）。工具会写出
`<基路径>.idx` 和 `<基路径>.00`、`.01`……文件按顶层目录分组切分，每片不超过 `--shard-mib`，
所以一片里装的是一类内容。

拷贝之前先验证：

```bash
python3 dm/tools/romfs_arc.py verify <基路径> <RomFS 目录>   # 逐字节比对每个文件
python3 dm/tools/romfs_arc.py list   <基路径> [路径]          # 列出某个目录
```

### 4. 构建 IPA

主构建脚本**默认打瘦身 IPA**（不含 RomFS；App 从 `Documents/romfs` 读游戏文件），所以第 1 步
已经产出。以后只想重新打包时：

```bash
GAME=<title id> W=<工作目录> PATCHED=<改写目录> \
  ROMFS=<RomFS 目录> MSL_IOS=<shader 目录> \
  dm/ios/tools/build_ipa.sh <输出.ipa>
```

`--full-romfs`（或 `DM_FULL_ROMFS=1`）把 RomFS 打进包里——上游行为，只对小体量游戏有意义。

### 5. 把归档拷到手机

整套放进 App 的 `Documents/romfs/`，保持基名不变：

```
Documents/romfs/romfs.idx
Documents/romfs/romfs.00
...
Documents/romfs/romfs.125
```

App 会先找 `romfs.idx`（`dm/ios/Sources/main.m` 的 `romfs_locate`）。没有索引时会回退到普通目录树，
所以对已有游戏没有任何影响。

索引可以放在以下任一位置，读取层按顺序尝试：

```
<DM_ROMFS>.idx
<DM_ROMFS>/romfs.idx
<DM_ROMFS>/romfs/romfs.idx
```

## 游玩

**触屏操控。** 两种布局（点顶部中央的按钮切换）：2D（左摇杆、A/B/X/Y、肩键、−/+）和 3D
（增加十字键、右摇杆和 L3/R3）。未连接手柄时，触到控件以外的区域会送到游戏的触屏。

**实体手柄**（GameController 框架：Xbox、PlayStation、Switch Pro 和 MFi 手柄都支持）连接后
会完全隐藏触屏控件，断开时恢复；期间所有触摸都送到游戏的触屏。按键按位置映射，与 Switch
手柄一致：下=B、右=A、左=Y、上=X，十字键和右摇杆同样保留。

**不改包调设置：** `Documents/env.txt`，每行一个 `KEY=VALUE`。常用的：

```
DM_LANG=zh-Hans        # 中文（默认 en-US）
DM_FPS_TARGET=30       # 限帧（省电；默认用 profile 的 fps_target）
DM_OPMODE=0            # 掌机模式：720p 渲染而不是底座的 1080p
```

**Mac 上**，启动器的「启动选项」面板有同样的选项（游戏语言、帧率、主机模式等），按游戏保存，重新构建后仍然保留。
面板里没有的设置，或想固定某项，可以写一个 `env.txt`，格式相同（`DM_LANG=zh-Hans`），放在两处之一：
`~/Library/Application Support/nxnative/<title ID>/env.txt` 优先，重新构建后仍在；
`<App>.app/Contents/Resources/dm/env.txt` 是 App 自带的。在加入语言选项之前构建的 App 需要重新构建一次才有该项。

**存档和日志**在「文件」App 里该 App 名字下：`save/` 和 `log.txt`。出问题时把 `log.txt`
发出来（上一次运行的是 `log.prev.txt`）。新场景第一次出现时短促卡顿是正常的：App 会为它
编译一次图形并记住。

## 换其他游戏

归档格式里没有任何与具体游戏绑定的东西：打包工具遍历你给的目录，读取层在那棵树里查路径。换游戏只需要：

1. 用 `nx_extract` 解出新游戏的 NSP（上游脚本会自动做）。
2. 用 `romfs_arc.py` 打包那个游戏的 `RomFS`。
3. 用新的 `GAME=` profile 重新构建 IPA（默认即瘦身包）。
4. 把新归档拷进 `Documents/romfs/`。

三点需要注意：

- **分片数不能超过 256。** 读取层每个分片占一个 fd 槽位（`romfs_arc.h` 的 `MAX_SHARDS`）。
  打包工具现在会拒绝写出超限的索引，并告诉你该用多大的 `--shard-mib`。《王国之泪》按 200 MiB
  需要 126 片；体积约它两倍的游戏需要 256 MiB 一片。
- **DLC 不走归档。** 追加内容仍然打进包里（`DmIOS.app/aoc/<index>/`），按目录挂载。多数 DLC
  体积很小，不影响安装；如果又撞上安装上限，把 DLC 从包里去掉即可，代价是游戏里看不到那几个 DLC。
- **`zip_store` 是每个游戏各自的。** profile 里列出已经是压缩格式、应当直接存储而不做 deflate 的
  扩展名（《王国之泪》是 `.zs`、`.bwav`、`.mc`、`.webm`、`.metallib`）。这只影响装 shader 库和
  表的那个包，与归档无关。

上游测试列表里的游戏（4–6 GB）按 200 MiB 大概需要 20–30 片，远低于上限，内存占用也远低于
《王国之泪》撞上的那个单 App 预算。

## 相对上游的改动

新增 5 个文件，修改 4 个。文件系统层保留原有的路径处理：归档打开时，`host_path_ex` 对归档挂载点上的
条目返回一个合成路径（`@romfsarc:<guest 路径>`），`OpenFile` / `GetEntryType` / `OpenDirectory`
和目录相关调用识别该前缀并转到归档层。归档条目的文件句柄用 bit 63 标记，不会与真实 fd 冲突；
`ReadFile` 会按文件大小截断（分片是平铺容器，不截断的话越界读会读到下一个文件的字节）。

| 文件 | 改动 |
|---|---|
| `dm/host/romfs_arc.h` | 新增 —— 归档格式与读取接口 |
| `dm/host/romfs_arc.c` | 新增 —— mmap 索引、二分查找、按需打开分片 |
| `dm/tools/romfs_arc.py` | 新增 —— pack / verify / list |
| `dm/host/tests/t_romfs_arc.c` | 新增 —— 遍历整份归档、校验每个文件 |
| `docs/ROMFS_ARCHIVE.md` | 新增 —— 格式与设计说明 |
| `dm/host/hle_fs.c` | 挂载并路由归档路径 |
| `dm/host/Makefile` | 编译 `romfs_arc.c` |
| `dm/ios/Sources/main.m` | `romfs_locate` 接受 `romfs.idx` |
| `dm/ios/tools/build_ipa.sh` | 默认瘦身包（`DM_FULL_ROMFS=1` = 上游完整包） |
| `scripts/build_ipa_from_nsp.py` | `--work-dir`（构建目录可离开 NSP 所在文件夹）；自动推导 `DOTNET_ROOT`（framework-dependent 的 `nx_extract` 在裸 shell 里缺它无法启动） |
| `frontend/` | 新增 —— macOS 图形界面前端（见 [图形界面](#图形界面)） |

挂载点按**目录**识别，而不是按名字：各游戏的挂载名不同（多数是 `rom`，《王国之泪》是 `content`）。

## 支持的游戏

本仓库自带 79 个游戏 profile。profile 决定了一个游戏能不能构建——build ID、内存布局、
shader 表、每个游戏各自的开关；本 fork 在此基础上加了 RomFS 归档层，让大体积游戏能装得下。

「需要的更新包」就是构建时严格校验的版本：更新包 NSP 的显示版本必须与 profile 注册的 build 一致
（本体自身的版本无所谓——更新会叠加在本体上）。「无（v0）」= 只需本体。

| 游戏 | Title ID | 需要的更新包 | 状态 |
|---|---|---|---|
| 超级马力欧 奥德赛 | `0100000000010000` | 1.4.1 (v393216) | 上游报告 iPhone 可玩 |
| 宝可梦 晶灿钻石 | `0100000011D90000` | 1.3.0 (v393216) | 上游报告 iPhone 可玩 |
| 逆转检察官 1&2 御剑精选集 | `010005501E68C000` | 1.0.0.2 (v131072) | 有 profile，未在手机上验证 |
| 空洞骑士：丝之歌 | `010013C00E930000` | 1.0.30000 (v655360) | 有 profile，未在手机上验证 |
| 数码宝贝物语 网络侦探 骇客追忆 | `010014E00DB56000` | 1.0.3 (v196608) | 有 profile，未在手机上验证 |
| 超级马力欧兄弟 惊奇 | `010015100B514000` | 1.2.1 (v327680) | 上游报告 iPhone 可玩 |
| 马力欧卡丁车 8 豪华版 | `0100152000022000` | 4.0.0 (v1441792) | 上游报告 iPhone 可玩 |
| 人狼村之谜 | `010020400E1C2000` | 无（v0） | 有 profile，未在手机上验证 |
| ANIMAL WELL | `010020D01AD24000` | 1.0.10 (v655360) | 上游报告 iPhone 可玩 |
| 超级马力欧 3D世界 + 狂怒世界 | `010028600EBDA000` | 1.2.2 (v262144) | 上游报告 iPhone 可玩 |
| 幽灵诡计 幻影侦探 | `010029B018432000` | 无（v0） | 上游报告 iPhone 可玩 |
| 塞尔达无双 灾厄启示录 | `01002B00111A2000` | 1.3.0 (v327680) | 上游报告 iPhone 可玩 |
| 蔚蓝 | `01002B30028F6000` | 1.4.1.1 (v589824) | 有 profile，未在手机上验证 |
| 高级战争 1+2 重制版 | `0100300012F2A000` | 无（v0） | 上游报告 iPhone 可玩 |
| 马力欧 + 疯狂兔子 星愿 | `0100317013770000` | 1.6.2225577 (v393216) | 有 profile，未在手机上验证 |
| Return of the Obra Dinn | `010032E00E6E2000` | 1.0.1 (v65536) | 有 profile，未在手机上验证 |
| 太阁立志传 V DX | `0100346017304000` | 1.1.1 (v131072) | 上游报告 iPhone 触屏可玩 |
| 大逆转裁判 1&2 成步堂龙之介的冒险 | `010036E00FB20000` | 无（v0） | 上游报告 iPhone 可玩 |
| 最终幻想 战略版 伊瓦利斯战记 | `010038B015560000` | 1.4.0 (v393216) | 有 profile，未在手机上验证 |
| 十三机兵防卫圈 | `01003FC01670C000` | 1.10 (v65536) | 上游报告 iPhone 可玩 |
| Blasphemous 2 | `010040801A4C8000` | 1.0.8 (v524288) | 有 profile，未在手机上验证 |
| 13 Sentinels: Aegis Rim (Japan) | `010045C014650000` | 无（v0） | 有 profile，未在手机上验证 |
| 猎天使魔女 3 | `01004A4010FEA000` | 1.2.0 (v131072) | 上游报告 iPhone 可玩 |
| 黑暗之魂 重制版 | `01004AB00A260000` | 1.0.3 (v196608) | 有 profile，未在手机上验证 |
| 星之卡比 探索发现 | `01004D300C5AE000` | 1.1.0 (v65536) | 有 profile，未在手机上验证 |
| 怪物火车 2 | `010051701FB46000` | 1.1.1 (v131072) | 上游报告 iPhone 可玩 |
| 歧路旅人 0 | `01005270232F2000` | 1.0.5 (v327680) | 有 profile，未在手机上验证 |
| 哈迪斯 | `0100535012974000` | 1.0.38233 (v589824) | 上游报告 iPhone 可玩 |
| Unicorn Overlord (Asia) | `010054B01AD92000` | 1.05 (v262144) | 有 profile，未在手机上验证 |
| 火焰纹章 风花雪月 | `010055D009F78000` | 1.2.0 (v327680) | 上游报告 iPhone 可玩 |
| 尼尔 自动人形 寄叶终结版 | `010056B015FE8000` | 1.0.3 (v131072) | 上游报告 iPhone 可玩 |
| 歧路旅人 | `010057D006492000` | 1.0.5 (v327680) | 有 profile，未在手机上验证 |
| 女神异闻录 5 皇家版 | `01005CA01580E000` | 1.0.2 (v65536) | 上游报告 iPhone 可玩 |
| 耀西的手工世界 | `01006000040C2000` | 1.0.1 (v65536) | 有 profile，未在手机上验证 |
| 最终幻想 共鸣 | `0100606026F12000` | 1.0.1 (v65536) | 上游报告 iPhone 可玩 |
| 脑锻炼 大人的 Nintendo Switch 训练 | `0100620012D6E000` | 1.2.0 (v131072) | 有 profile，未在手机上验证 |
| Persona 4 Golden | `010062B01525C000` | 1.0.2 (v131072) | 有 profile，未在手机上验证 |
| Mario + Rabbids Kingdom Battle | `010067300059A000` | 1.9.589692 (v589824) | 有 profile，未在手机上验证 |
| 圣兽之王 | `010069401ADB8000` | 1.05 (v262144) | 有 profile，未在手机上验证 |
| Blasphemous | `0100698009C6E000` | 1.0.8 (v524288) | 有 profile，未在手机上验证 |
| 真·女神转生 V Vengeance | `010069C01AB82000` | 1.0.3 (v196608) | 上游报告 iPhone 可玩 |
| 任天堂明星大乱斗 特别版 | `01006A800016E000` | 13.0.5 (v2031616) | 上游报告 iPhone 可玩 |
| 塞尔达传说 织梦岛 | `01006BB00C6F0000` | 1.1.0 (v131072) | 上游报告 iPhone 可玩 |
| 勇者斗恶龙 XI S 寻觅逝去的时光 决定版 | `01006C300E9F0000` | 1.0.4 (v262144) | 有 profile，未在手机上验证 |
| 集合啦！动物森友会 | `01006F8002326000` | 3.0.3 (v2228224) | **本 fork 已验证** —— 构建、安装、在 iPhone 上流畅运行；103,645 个文件归档成 72 片 |
| AI 梦境档案 涅槃肇始 | `0100713016CCC000` | 1.0.2 (v131072) | 上游报告 iPhone 可玩 |
| 异界锁链 | `01007300020FA000` | 1.0.1 (v65536) | 上游报告 iPhone 可玩 |
| 异度神剑 3 | `010074F013262000` | 2.2.1 (v720896) | 有 profile，未在手机上验证 |
| 猎天使魔女 | `010076F0049A2000` | 1.1 (v65536) | 上游报告 iPhone 可玩 |
| 猎天使魔女 2 | `01007960049A0000` | 1.2 (v131072) | 上游报告 iPhone 可玩 |
| 传送门 | `01007BB017812000` | 1.0.3 (v196608) | 上游报告 iPhone 可玩 |
| 塞尔达传说 旷野之息 | `01007EF00011E000` | 1.9.0 (v1114112) | 上游报告 iPhone 可玩 |
| BALL x PIT | `010086A022444000` | 1.293 (v393216) | 上游报告 iPhone 可玩 |
| AI 梦境档案 | `010089B00D09C000` | 1.0.1 (v65536) | 上游报告 iPhone 可玩 |
| 命运石之门 RE:BOOT | `01008BC024FDE000` | 1.0.3 (v131072) | 有 profile，未在手机上验证 |
| 星之海 | `01008C0016544000` | 2.0.59001 (v786432) | 上游报告 iPhone 可玩 |
| 塞尔达传说 智慧的再现 | `01008CF01BAAC000` | 1.1.0 (v196608) | 上游报告 iPhone 可玩 |
| 十三机兵防卫圈（亚洲版） | `01008D7016438000` | 无（v0） | 上游报告 iPhone 可玩 |
| 宝可梦 盾 | `01008DB008C2C000` | 1.3.2 (v458752) | 上游报告 iPhone 可玩 |
| 密特罗德 生存恐惧 | `010093801237C000` | 2.1.0 (v327680) | 上游报告 iPhone 可玩 |
| 超级马力欧 银河 | `010099C022B96000` | 1.3.1 (v327680) | 上游报告 iPhone 可玩 |
| 奇诺比奥队长 宝物追踪 | `01009BF0072D4000` | 1.4.2 (v393216) | 有 profile，未在手机上验证 |
| 大金刚国度 归乡 HD | `01009D901BC56000` | 1.1.0 (v65536) | 有 profile，未在手机上验证 |
| 哈迪斯 II | `0100A00019DE0000` | 1.0.137848 (v1) | **本 fork 已验证** —— 构建、安装、在 iPhone 上运行；33 个文件的归档 |
| 歧路旅人 II | `0100A3501946E000` | 1.1.1 (v131072) | 上游报告 iPhone 可玩 |
| Pokémon Scarlet | `0100A3D008C5C000` | 无（v0） | 有 profile，未在手机上验证 |
| 茶杯头 | `0100A5C00D162000` | 1.3.7 (v655360) | 有 profile，未在手机上验证 |
| 火焰纹章 结合 | `0100A6301214E000` | 2.0.0 (v327680) | 上游报告 iPhone 可玩 |
| Absolum | `0100A83022A22000` | 1.1.1 (v393216) | 有 profile，未在手机上验证 |
| 勇者斗恶龙 VII 重制版 | `0100A9D01C446000` | 1.2.0 (v131072) | 有 profile，未在手机上验证 |
| 宝可梦 剑 | `0100ABF008968000` | 1.3.2 (v458752) | 上游报告 iPhone 可玩 |
| 怪物猎人 崛起 | `0100B04011742000` | 16.0.2 (v2228224) | 有 profile，未在手机上验证 |
| 皮克敏 4 | `0100B7C00933A000` | 1.1.1 (v262144) | 上游报告 iPhone 可玩 |
| FINAL FANTASY RESONANCE (Asian release) | `0100B8A026F14000` | 1.0.1 (v65536) | 有 profile，未在手机上验证 |
| NieR:Automata The End of YoRHa Edition | `0100B8E016F76000` | 1.0.3 (v131072) | 有 profile，未在手机上验证 |
| 马力欧 VS 大金刚 | `0100B99019412000` | 1.0.1 (v65536) | 上游报告 iPhone 可玩 |
| FINAL FANTASY X/X-2 HD Remaster | `0100BC300CB48000` | 无（v0） | 有 profile，未在手机上验证 |
| 凯瑟琳 浓郁口感 | `0100BF00112C0000` | 1.0.1a (v131072) | 有 profile，未在手机上验证 |
| 大金刚国度 热带冻结 | `0100C1F0051B6000` | 1.0.2 (v131072) | 有 profile，未在手机上验证 |
| 三国志 8 REMAKE | `0100C2A01A730000` | 1.1.3 (v851968) | 上游报告 iPhone 可玩（需手柄） |
| 小丑牌 | `0100CD801CE5E000` | 1.1.3 (v851968) | 上游报告 iPhone 可玩 |
| FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition | `0100CE4010AAC000` | 1.0.3 (v196608) | 有 profile，未在手机上验证 |
| Silver Pines | `0100D5B026844000` | 无（v0） | 有 profile，未在手机上验证 |
| 节奏天国 Groove | `0100D9F01D474000` | 无（v0） | 有 profile，未在手机上验证 |
| 路易吉洋馆 3 | `0100DCA0064A6000` | 1.4.0 (v327680) | 上游报告 iPhone 可玩 |
| Patrick's Parabox | `0100E44016C22000` | 1.0.1 (v65536) | 有 profile，未在手机上验证 |
| 星露谷物语 | `0100E65002BB8000` | 1.6.15.13 (v1310720) | 上游报告 iPhone 可玩 |
| Xenoblade Chronicles 2 | `0100E95004038000` | 2.1.0 (v983040) | 有 profile，未在手机上验证 |
| 纸片马力欧 千年之门 | `0100ECD018EBE000` | 1.0.1 (v65536) | 有 profile，未在手机上验证 |
| 塞尔达传说 王国之泪 | `0100F2C0115B6000` | 1.4.3 (v720896) | **本 fork 已验证** —— 构建、安装、在 iPhone 上运行；304,243 个文件归档成 127 片，逐字节校验通过 |
| 宝可梦传说 Z-A | `0100F43008C44000` | 2.0.2 (v393216) | 有 profile，未在手机上验证 |
| 脑力记忆训练学院 | `0100F5D01DA3A000` | 无（v0） | 有 profile，未在手机上验证 |
| 超级马力欧 银河 2 | `0100FD8022DAA000` | 1.4.0 (v393216) | 有 profile，未在手机上验证 |
| Xenoblade Chronicles: Definitive Edition | `0100FF500E34A000` | 1.1.2 (v196608) | 有 profile，未在手机上验证 |

「本 fork 已验证」表示完整走通了整条链路：构建、装到 iPhone、运行，归档还逐字节比对过源文件。
「上游报告 iPhone 可玩」是上游项目的结果，本 fork 未重新测试。只有 profile 不保证游戏能启动——
游戏所需的宿主改动属于上游工作，本 fork 跟随上游。

## 验证情况

- **《王国之泪》**（0100F2C0115B6000，v1.0.0 + 更新 1.4.3）：304,243 个文件打成 127 个文件；
  304,243 个文件全部与源目录逐字节比对通过（`verify: OK`）；游戏从归档正常运行于 macOS
  （30 fps，1,905 帧）。
- **《哈迪斯 2》**（0100A00019DE0000，本体 + 更新 1.0.137848）：5,258 个文件打成 33 个文件，
  逐字节比对通过，游戏从归档正常运行于 macOS（2,100 帧，1,772 次归档读取）。更新包无需特殊
  处理：`nx_extract` 本来就用 `OpenFileSystemWithPatch` 把更新层叠在本体上，解出的 RomFS
  ——也就是归档——就是合并结果。**在 iPhone 上可玩**（12 GB 设备，AltStore Classic 2.3），
  前提是内存 entitlement 生效——见下。
- C 读取层遍历全部 304,243 个《王国之泪》文件、2,667 个目录，耗时 7.6 秒。

**jetsam 预算是大体积游戏的限制，而它是可以提高的。** 没有
`com.apple.developer.kernel.increased-memory-limit` 时，iPhone 给这个 App 约 3,375 MB（12 GB
设备实测：《王国之泪》进大地图时被杀，常驻 3,342 MB、余量 33 MB；渲染缩放降到 0.5 无改善，
说明瓶颈在 guest 堆而不是 GPU）。App 请求了这个 entitlement，`build_ipa.sh` 把它嵌进占位用的
ad-hoc 签名——无签名的二进制没有可供侧载工具读取 entitlement 的签名，不做这一步请求就会丢失。
**AltStore Classic 2.2+**、**Impactor** 和 **Xcode + Personal Team** 会保留它；**SideStore**
配合免费 Apple ID 需要对 App ID 做一次性修复；**Sideloadly** 不会。步骤和判断方法（log.txt 里
resident + headroom：约 3,375 MB = 未生效，6–8 GB = 已生效）见
[dm/ios/ENTITLEMENTS.md](dm/ios/ENTITLEMENTS.md)。

## 限制

- **只读。** 归档从不写入；存档和临时数据照旧走各自的挂载点。
- **大小写敏感查找。** 名称按源目录树原样存储，所以宿主的 APFS 大小写不敏感别名机制对归档条目
  不适用。
- **符号链接在打包时展开。** 目前支持的游戏 RomFS 里没有符号链接。
- **索引常驻内存。** 《王国之泪》是 28 MB（其中 17.9 MB 是名称）。分片不常驻。
- **不做去重或压缩。** 分片是源字节原样，所以 `verify` 就是直接比对，重复打包的结果是确定的。

## 致谢

**社区贡献者** —— 这个项目的代码不只是一个维护者的输出：

- **[v0lumehi](https://github.com/v0lumehi)** —— **Mac 前端的启动器界面**（PR [#27](https://github.com/LNPANDY/NX2Apple/pull/27)，40 个文件）：游戏库、封面图、每游戏启动选项、真进度流、能真正结束整个构建进程组的 Stop。Mac 端从"一个构建表单"变成了"打开像一台 Switch 的启动器"的第一版。
- **[m1guelpf](https://github.com/m1guelpf)**（Miguel Piedrafita）—— 两个 HLE 修复（PR [#24](https://github.com/LNPANDY/NX2Apple/pull/24)、[#26](https://github.com/LNPANDY/NX2Apple/pull/26)）：补上了 `EnableAlbumImageTakenNotification` 和 `CreateWithAdjustableSystemClock` 及其快照类型字节——两个原本会让游戏读到空指针的缺失条目，各带测试。

想加入这个列表？上面的[参与贡献](#参与贡献着色器与新游戏)写了怎么开始；issue 里附上完整日志的报告和带测试的修复最快。

所有模拟相关的工作都是别人的。本仓库在其之上增加了归档子系统：

- **[nxnative](https://github.com/seedds/nxnative)**（MIT）—— 本仓库所基于的原生执行工具链：
  NSO 重写器、Horizon 宿主层、NVN-on-Metal、各游戏 profile 和 iOS 外壳。
- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)**（MIT）—— nxnative 由之发展而来的
  原始原生执行方案。
- **Ryujinx**（MIT）—— 把 Maxwell 着色器翻译成 SPIR-V 的翻译器。
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)** —— Horizon 同步语义的参考实现。
- **[LibHac](https://github.com/Thealexbarney/LibHac)** —— `nx_extract` 用它读取 NSP 并叠加更新。
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)** —— SPIR-V 转 Metal Shading Language。
- **yuzu**、**deko3d**、**libvpx**、**stb_vorbis**、**libdeflate** —— 各自贡献见上游致谢列表。

`dm/third_party` 里随附了其他项目及其许可证（[列表](dm/third_party/README.md)）。

## 法律

**本项目是什么。** 一个为你**已拥有**的游戏做构建的工具。它读取你在自己机器上从自己的卡带和购买中
导出的文件，产出一个装到你自己的设备上的安装包。本仓库、App 和任何 Release 中都不包含、也不分发
任天堂的代码、美术、文本、数据、着色器、固件、密钥或任何其他受版权保护的内容。

**它做不到什么。** 整条流水线没有游戏和密钥的来源：必须由用户提供自己的 `prod.keys` 和自己的
NSP/XCI 导出文件，且不连接任何服务器。它不绕过、不移除、也不再分发任何保护——LibHac 用用户自己的
密钥打开用户自己的导出文件，和主机读取卡带执行的是同一种操作。

**商标。** 与任天堂无关联，也未获得其赞助或认可。"Nintendo Switch" 及各游戏名称是任天堂株式会社的
商标；其他商标归各自权利人所有。

**你的责任。** 制作个人备份副本的法律因国家而异，有些地方完全不允许。你有责任了解并遵守所在地的
法律，并且绝不分发游戏文件、密钥或由它们构建出的安装包——本项目的产物仅供在你自己的硬件上个人使用。
喜欢哪个游戏，请购买它。

**下架。** 如果你认为本仓库中的任何内容侵犯了你的权利，请开 issue 或直接联系维护者；有效的权利
主张会得到及时处理，包括删除相关内容乃至整个仓库。

**无担保。** 本软件按 [LICENSE](LICENSE) 中的许可证（本 fork 在上游之上有所附加，见致谢）以"现状"
提供，不附带任何明示或默示的担保。使用风险自负。
