# NX2Apple v0.5.0 — release notes

This is the text of the [v0.5.0 release](https://github.com/LNPANDY/NX2Apple/releases/tag/v0.5.0). Earlier releases are on the releases page. English first, then Chinese, as two complete halves — see RELEASE-NOTES-GUIDE.md.

## What this release does

**The Mac launcher arrives, and the iPhone's game data finally sticks.** The launcher is a real console-style screen now: launch options live in the game's own saved-choices store (the same one upstream reads), the library's Manage menu opens with a controller, and a bare Apple ID — no development certificate — can install, because Xcode creates everything at the first install. On the iPhone, choosing game data works across launches, an app with no data yet boots into the launcher instead of a dead end, a pick applies the moment Play is pressed, and the installer asks before copying gigabytes over USB. The build tools update themselves, even from an old ZIP copy.

## New

- **Launch options live in the game's own store**: one string per setting (`launcher.<VAR>`) in the app's preferences domain, exactly where upstream's launcher reads them — Finder and Dock starts included. Only non-default values are kept, an earlier launcher's choices migrate once, and schema 1 is read properly: sub-settings appear only when their parent has the value (`needs`), sections the launcher has no name for draw after the known ones in list order, and range limits come from the row. A newer schema is read as far as it can be and noted in the log, never refused.
- **The library's Manage menu in the launcher's own style** — and a controller can open and drive it.
- **Build tools update themselves**: a ZIP copy of an old release is connected to git by itself when the app opens (your own edits are preserved on a branch), and a build refuses to start when the tools are older than the app instead of failing at the last step.
- **Install with just an Apple ID**: signing teams come from Xcode's provisioning preferences (personal teams are labelled), merged with the certificates'. With no certificate at all, Xcode creates one at the first install (`-allowProvisioningUpdates`). The messages say so, and with neither an Apple ID nor a certificate they say exactly where to sign in.
- **The installer asks before copying game files**: USB from the Mac runs at about 25–70 MB/s, so the dialog offers transfer now or skip — the game installs either way, and the outcome card gains a "Game data (romfs.img)" row with Reveal in Finder for a manual copy (a fast external drive handed to the device is quicker, and the launcher's Game data picker loads from it).
- **Issue forms**: game, build and launcher problems each ask for what a report needs (versions, device, Copy diagnostics, the game's log) and refuse to submit without it. A PR template and CONTRIBUTING.md set the same rules for tools.

## Fixes

- **iPhone: choosing game data sticks.** The bookmark is written while the Files app's security scope is held (one written without it resolves to nothing from the next launch on — every pick read as "the app was signed differently"), saved only after a round-trip resolves, and a stale-but-readable bookmark rewrites itself instead of making you pick again. The resolved scope stays held for the session, since the game reads the image the whole time.
- **iPhone: no game data is no dead end.** A fresh install with nothing in Documents and no pick ever made boots into the launcher (the old build stopped on a static "Game files not found" page that never mentioned the picker), and Play (re)locates the data first — a pick made this session applies at once, with save/temp following the final location. An app without a launcher falls back to the static hint.
- **iPhone: the signing retry keeps its stage row.** The team-variant retry appended a second "Sign for …" row with the same id that no update ever reached, so it spun for ever after the build moved on. A retried stage now reuses its row.
- **Mac: every extracted game version is kept as the build resource it is.** The versions a profile's shader tables were made from are inputs to the shader split on every build, so deleting the packed version's siblings traded a full re-extraction of the base game for disk space — the wrong trade, and it is undone.
- **Sync: the next upstream sync runs.** Upstream's latest commits stopped the sync and would have silently lost fork code. Every patcher is now tested against real upstream in CI, a `--check-protection` run lists any hand-edited file no table covers, and files the fork owns outright are registered so a sync cannot revert them.

## Known issues

- **Mods have not been played with a real mod yet**: the layouts and the environment string are verified, but the actual overlay is not.
- **Windows**: not provided on this page — the front end is verified on real hardware, the full build pipeline is not. The Actions artifact `NS-Port-Builder-qt-windows-x64` has the current front end.

## Install

- **macOS**: download `NX2Apple-macOS-arm64.zip`, unzip, then right-click → Open on first launch. In-app updates work from 0.4.9 on under the NX2Apple name (older versions: download this one by hand).
- **Windows**: not provided on this page, but the Actions artifact has the Qt front end.

## Credits

- **v0lumehi**: the saved-choices store, the Manage menu, the tools self-update, the Xcode team reader, the sync overhaul, the compile-gate catch, and the issue forms — eleven reviewed pull requests in two days.
- **GabeThe21stGamer**: the report that exposed the stale-tools and no-certificate paths (#87), and the free-Apple-ID test of the certificate-less install.

---

## 这一版做了什么

**Mac 启动器来了，iPhone 的游戏数据终于稳了。** 启动器成了真正的游戏机风格界面：启动选项存进游戏自己的选择存储（与上游读的是同一处），游戏库的 Manage 菜单用手柄就能打开，只有普通 Apple ID、没有任何开发证书也能安装——Xcode 在第一次安装时自动把证书办齐。iPhone 这边，选择游戏数据在重启后依然有效，还没有数据的 App 会直接进启动器而不是死页面，选完按 Play 立即生效，安装器在通过 USB 拷贝几个 GB 之前会先来询问。构建工具会自己更新了，连旧版 ZIP 拷贝也能接上。

## 新增

- **启动选项存进游戏自己的存储**：每个设置一条字符串（`launcher.<VAR>`），写在 App 的偏好域里——正是上游启动器读取的位置，Finder 和 Dock 启动同样生效。只保留非默认值，旧启动器的选择一次性迁移。schema 1 完整支持：父项有值才显示子项（`needs`）、启动器不认识的分组按列表顺序排在已知分组之后、范围上下限来自条目本身。更新版的 schema 能读多少读多少并写进日志，绝不拒绝。
- **游戏库的 Manage 菜单换成启动器同款风格**——并且可以用手柄打开和操作。
- **构建工具自己更新**：旧版 ZIP 拷贝在 App 打开时自动接上 git（你自己的修改保留在分支上），工具比 App 旧时直接拒绝开始构建，而不是到最后一步才失败。
- **只凭 Apple ID 就能安装**：签名团队从 Xcode 的开发者偏好里读取（个人团队会标注），与证书里的合并。一个证书都没有时，Xcode 在第一次安装时自动创建（`-allowProvisioningUpdates`），提示语会说明这一点，既没有 Apple ID 也没有证书时，会告诉你确切该去哪里登录。
- **安装器在拷贝游戏文件前先询问**：Mac 经 USB 向 iPhone 只有约 25–70 MB/s，弹窗提供"现在传输"或"暂不传输"——两种选择游戏都会装上，结果卡片新增"游戏数据（romfs.img）"一行，带"在访达中显示"，方便手动拷贝（把高速外接盘直接连 iPhone 更快，启动器的"选择游戏数据"可以从那里加载）。
- **Issue 表单**：游戏/构建/启动器三类问题各自要求报告所需的信息（版本、设备、Copy 诊断、游戏日志），缺了就提交不了。PR 模板和 CONTRIBUTING.md 给工具立了同样的规矩。

## 修复

- **iPhone：选择游戏数据终于能记住。** 书签在 Files App 的安全作用域被持有期间写入（不持作用域写出的书签从下次启动起就解析不了——于是每次选择都报"签名不同"），保存前先验证能读回，能解析但过期的书签自动重写而不必重选。解析出的作用域在整个会话期间持有，因为游戏全程都在读镜像。
- **iPhone：没有游戏数据不再是死路。** 全新安装、Documents 里没有数据、也从没选过路径时，App 会正常进启动器（旧版停在一句静态的"Game files not found"上，绝口不提选择器），按 Play 时先重新定位数据——本次会话的选择立即生效，存档/临时目录跟着最终位置走。没有启动器的极简包才回退到静态提示。
- **iPhone：签名重试复用同一行。** 团队变体重试会追加一行同 ID 的"为 … 签名"，而所有更新都只打到第一行——构建都走完了它还在转圈。重试的步骤现在复用自己的行。
- **Mac：每个解包版本都作为构建资源保留。** 游戏 shader 表登记的来源版本是每次构建 shader split 的输入，删掉打包版本之外的版本，等于拿整份基础版重解去换磁盘空间——这笔账不划算，已撤销。
- **同步：下一次上游同步能跑通了。** 上游最新提交会让同步中断并悄悄丢掉 fork 代码。现在每个补丁器都在 CI 里对着真实上游测试，`--check-protection` 会列出任何没被登记的手改文件，fork 完全 own 的文件也已登记、同步不会回退它们。

## 已知问题

- **Mods 还没有用真正的 mod 实测过**：布局和环境变量已验证，实际的叠加加载没有。
- **Windows**：本页不提供——前端在真机上验证过，完整构建流水线没有。Actions 产物 `NS-Port-Builder-qt-windows-x64` 是当前的前端。

## 安装

- **macOS**：下载 `NX2Apple-macOS-arm64.zip`，解压后右键 → 打开（首次）。0.4.9 起 App 内更新在 NX2Apple 名下正常工作（更早的版本请这次手动下载）。
- **Windows**：本页不提供，Actions 产物里有 Qt 前端。

## 致谢

- **v0lumehi**：选择存储、Manage 菜单、工具自更新、Xcode 团队读取、同步大修、编译门禁拦截、issue 表单——两天里十一连审通过的 PR。
- **GabeThe21stGamer**：暴露了旧工具与无证书两条路径的报告（#87），以及免证书安装的免费 Apple ID 实测。
