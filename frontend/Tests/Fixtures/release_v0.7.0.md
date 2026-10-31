## What this release does

**The launcher becomes the whole computer a player needs — and then some.** A first-run wizard walks a new player through Xcode, keys and games with the tools already inside the app; the library goes full-screen controller-first like a Switch home menu; saves follow a game between Mac and iPhone through one iCloud Drive folder; a deleted app reinstalls in seconds; and a free Apple ID's 7-day signature renews in place. The repository's upstream sync is a patch queue now, so fixes land faster and nothing is lost.

## New

- **Guided first-run setup** (#119, #120): welcome → platform (Mac, iPhone or both) → Xcode → keys → games. The Xcode step opens the App Store and polls for the install, runs one administrator prompt to switch the toolchain and finish the first launch, then downloads the Metal Toolchain and (iPhone/both) the iOS platform with progress. Everything else installs in the background, with a real "Installing…" state per tool. Setup resumes where it left off; a player whose setup is already complete never sees it; Settings has "Run setup again".
- **The build tools and a Python ship inside the app** (#154): zstd, glslangValidator, spirv-cross, xcodegen and CPython 3.13 with every package the build needs — all from pinned, checksummed sources, license files included. Nobody installs Homebrew or Python; the floor stays at macOS 13.
- **Reinstall without rebuilding** (#155): the install card gains Reinstall — `devicectl` puts the signed app from the last build back on the device in seconds, with game data and saves intact. **Save IPA…** exports it as a standard IPA for a sideloader or another Mac. The Manage menu carries both, and the app knows whether each game is actually installed on the connected device.
- **Signature expiry and renewal** (#156): the game card shows the days left on a free Apple ID's 7-day provisioning (orange at two days or fewer). Renew re-signs in place — Xcode reuses every compiled product, only the signature changes — then installs over itself. Game data is preserved.
- **Console mode** (#169): with a controller connected, press Select (DualShock Share, DualSense Create, Xbox View, Nintendo Minus) or View → Console Mode: the library goes full screen, controller-first — covers, launch options through the saved choices, battery chips, Controllers list, glyphs that follow the last input. D-pad and stick move, A activates, B backs out, + and X open game options, Y opens Controllers. Also reachable at Option-Command-K.
- **Cloud saves** (#185): a game's Mac app and iPhone app play on from one save through an iCloud Drive folder the player picks in each launcher. Whole-file sync with SHA-256 checks, per-date backups of every replaced save, both directions verified with Tears of the Kingdom on real devices.
- **Build failures become rows that name the reason and the next step** (#166/#205): the Intel-Python, shader-translator, iOS-SDK and CommandLineTools stops each get their explanation plus a Build anyway button where it makes sense.
- **Swedish localization** (#168): the whole interface, selected from the device language.
- **A player's README**: install, play, games, limitations — 1,900 words instead of 8,000. Building from source moved to BUILDING.md, the games gallery to GAMES.md, the update history to CHANGELOG.md.
- **Issue triage in report mode** (#143): the Copilot CLI labels new issues, asks for missing form answers, and matches `[RED]` log lines against the symptom index — labels apply, the comment lands in the job summary for a human to post.
- **Windows**: the dependency panel guides the two Apple downloads (iPhoneOS SDK, Metal Developer Tools) with the exact steps, and a deep-dependency crash in the link probe is fixed (#192/#196).

## Fixes

- **Xcode installed but never opened**: the dependency row said "no iOS SDK" and offered a download that could not run (xcode-select still on CommandLineTools). It is its own state now — Xcode installed, not selected — with a one-click Fix.
- **A failed dependency install names the reason**: the row shows the tool's own error line, and for known causes the exact command (Homebrew's folder owned by another user → `sudo chown -R $(whoami) /opt/homebrew`; Homebrew missing → brew.sh; the Xcode license → `sudo xcodebuild -license accept`; network → check proxy).
- **A bundle-ID check no longer crashes on another user's project**: the Xcode workspace records absolute paths, and a new macOS user inherits the first user's entries — unreadable projects are pruned automatically.
- **The diagnostics block no longer prints `(null)`** for the second version in a dependency description, and the updater's dependency check finds the Pythons `uv` installs.
- **The updater's strings survive CI**: the shared localization table is the single source for both front ends.

## Known issues

- **Mods have not been played with a real mod yet**: the layouts and the environment string are verified; the actual overlay is not.
- **Route C M1** (game modules as an opt-in framework) is in review and not part of this release.
- **Windows**: the full build pipeline is not verified on real hardware; the front end is. The Actions artifact `NS-Port-Builder-qt-windows-x64` has the current front end.

## Install

- **macOS**: download `NX2Apple-macOS-arm64.zip`, unzip, right-click → Open on first launch. In-app updates work from 0.4.9 on under the NX2Apple name.
- **Windows**: not provided on this page; the Actions artifact has the Qt front end.

## Credits

- **v0lumehi**: onboarding, bundled tools, the patch-queue sync model, console mode, build-failure hints, diagnostics, upstream-first docs, issue triage — twenty reviewed pull requests.
- **dreamw0rk**: cloud saves, verified with Tears of the Kingdom on both platforms.
- **yeager**: Swedish localization.
- **pyxl-dev**: Luigi's Mansion 3 depth_mode fix.
- **subyoung**: frame-time recording, return-after-play.
- **a834354487 / MilesWanli**: the Pythons `uv` installs finding.
- **lex2ok**: the Resume layer for the shader/Xcode build steps.
- **tmrsm**: Windows IPA build handoffs.

---

## 这一版做了什么

**启动器成为玩家需要的整台电脑——还不止。** 首次运行向导带新玩家走完 Xcode、密钥和游戏，工具已内置在 App 里；游戏库变全屏手柄操作，像 Switch 主菜单；存档通过一个 iCloud Drive 文件夹在 Mac 和 iPhone 之间跟随游戏；删掉的 App 几秒重装；免费 Apple ID 的 7 天签名原地续签。仓库的上游同步现在是补丁队列：修复落地更快，什么都不丢。

## 新增

- **引导式首次启动**（#119、#120）：欢迎 → 平台（Mac、iPhone 或都要）→ Xcode → 密钥 → 游戏。Xcode 步骤打开 App Store 并轮询安装完成，跑一次管理员密码切换工具链并完成首次启动，然后带进度下载 Metal 工具链和（iPhone/都要）iOS 平台。其余工具后台依次安装，每个工具有真实的"正在安装…"状态。设置中断后接着来；已配置好的玩家不会看到；设置里有"重新运行设置"。
- **构建工具和 Python 内置在 App 里**（#154）：zstd、glslangValidator、spirv-cross、xcodegen 和 CPython 3.13（含构建需要的全部包）——全部来自 sha256 锁定的源码，附许可文件。没人需要装 Homebrew 或 Python；最低系统保持 macOS 13。
- **不重构建就能重装**（#155）：安装卡片多了"重装"——`devicectl` 把上次构建的已签名 App 秒回设备，游戏数据和存档完好。**保存 IPA…** 导出为标准 IPA 给侧载器或另一台 Mac。管理菜单也有，且 App 知道每个游戏是否真的装在连接的设备上。
- **签名到期与续签**（#156）：游戏卡片显示免费 Apple ID 的 7 天签名剩余天数（剩两天变橙）。续签原地重签——Xcode 复用全部编译产物，只换签名——然后装回手机。游戏数据保留。
- **主机模式**（#169）：手柄连接后按 Select（DualShock Share、DualSense Create、Xbox View、Nintendo Minus）或视图 → 主机模式：游戏库变全屏、手柄优先——封面、启动选项走保存的选择、电量徽章、手柄列表、跟随最后输入的按键图形。十字键和摇杆移动，A 启动，B 返回，+ 和 X 打开游戏选项，Y 打开手柄列表。也可用 Option-Command-K。
- **云存档**（#185）：游戏的 Mac 版和 iPhone 版通过玩家在各自启动器里选的 iCloud Drive 文件夹接力同一个存档。整文件同步 + SHA-256 校验，每次替换的存档按日期备份，两个方向都在真机用王国之泪验证过。
- **构建失败变成行提示**（#166/#205）：Intel-Python、着色器翻译器、iOS-SDK、CommandLineTools 四种停顿各自有解释，合理的场景给"仍然构建"按钮。
- **瑞典语本地化**（#168）：整个界面，按设备语言选择。
- **玩家版 README**：安装、玩、游戏、限制——1900 词而不是 8000。源码构建移到 BUILDING.md，游戏画廊移到 GAMES.md，更新历史移到 CHANGELOG.md。
- **Issue triage 报告模式**（#143）：Copilot CLI 给新 issue 打标签、追问缺失的表单项、把 `[RED]` 日志行对照症状索引——标签生效，评论落在 job summary 由人来发。
- **Windows**：依赖面板引导两个 Apple 下载（iPhoneOS SDK、Metal Developer Tools）的确切步骤；修复链接探针里的深度依赖崩溃（#192/#196）。

## 修复

- **Xcode 装了但没打开过**：依赖行说"缺 iOS SDK"并给了跑不了的下载按钮（xcode-select 还指着 CommandLineTools）。现在这是独立状态——Xcode 已安装但未选中——带一键"修复"。
- **依赖安装失败说出原因**：行内显示工具自己的错误行，已知原因给确切命令（Homebrew 目录属主不对 → `sudo chown -R $(whoami) /opt/homebrew`；没装 Homebrew → brew.sh；Xcode 许可 → `sudo xcodebuild -license accept`；网络 → 检查代理）。
- **bundle-ID 检查不再崩在别的用户的项目上**：Xcode workspace 记录绝对路径，新 macOS 用户继承第一个用户的条目——读不了的项目自动清理。
- **诊断块不再打印 `(null)`**：依赖描述里的第二个版本号；更新器的依赖检查找到了 `uv` 安装的 Python。
- **更新器的字符串在 CI 中不再丢失**：共享本地化表是两个前端的唯一来源。

## 已知问题

- **Mods 还没有用真正的 mod 实测过**：布局和环境变量已验证，实际的叠加加载没有。
- **路线 C M1**（游戏模块作为可选的 framework）在评审中，不在这个版本里。
- **Windows**：完整构建流水线未在真机验证；前端已验证。Actions 产物里有当前前端。

## 安装

- **macOS**：下载 `NX2Apple-macOS-arm64.zip`，解压后右键 → 打开（首次）。0.4.9 起 App 内更新在 NX2Apple 名下正常工作。
- **Windows**：本页不提供；Actions 产物里有 Qt 前端。

## 致谢

- **v0lumehi**：引导流程、内置工具、补丁队列同步模型、主机模式、构建失败提示、诊断、上游优先文档、issue triage——二十个经过评审的 PR。
- **dreamw0rk**：云存档，双平台用王国之泪验证。
- **yeager**：瑞典语本地化。
- **pyxl-dev**：Luigi's Mansion 3 depth_mode 修复。
- **subyoung**：帧时间记录、游戏退出后回前台。
- **a834354487 / MilesWanli**：`uv` 安装的 Python 的检测。
- **lex2ok**：shader/Xcode 构建步骤的 Resume 层。
- **tmrsm**：Windows IPA 构建交接。

