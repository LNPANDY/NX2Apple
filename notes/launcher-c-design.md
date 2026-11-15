# 架构 C 具体设计：壳 App + 每游戏 framework（dlopen）

状态：设计稿 v1（2026-10-26）。前置阅读：`docs/ROADMAP.md` 第 6 节、`docs/WORK-IN-PROGRESS.md` C5/C7、
`dm/host/hle_profile.{c,h}`（运行时 profile，已在 main，`3b36083`）。

目标（用户原话）：**"打开启动器就像打开了一台 Switch"**——一个壳 App，里面看到多个已构建的游戏，
点一个进入那个游戏。架构 A（进行中，WIP:41-47）交付按游戏隔离的数据布局。本文设计 C——壳 +
每游戏 framework——把"多个游戏装进一个 App"的**代码**维度做对。

本文回答六个问题：framework 边界、与架构 B 的真实差异（含 codesign 的诚实结论）、构建系统改造、
运行时选择器、风险清单、工作量分解。每个结论都给证据（文件与行号，或外部来源）。
**一句话结论先放在这里：C 不能"不重签就加游戏"——iOS 只允许 dlopen 安装时已在签名 bundle 内的代码，
C 的真实价值是"每个游戏一个独立 Mach-O（各自的 255 section 预算、增量链接、坏一个不坏全局）"，
不是 unbounded。第 2 节有完整论证。**

---

## 1. 壳 App + framework 的边界划在哪

### 1.1 两个候选布局

**方案 FR（推荐）：framework = 纯模块容器。** 壳 App 内含一份完整宿主（loader + 全部 HLE + iOS front，
即今天 `dm/ios/Sources/main.m` + `dm/host/*` 的编译产物），每个游戏 framework 里只有：

| framework 内容 | 来源 | 现状对应 |
|---|---|---|
| `<game>` dylib：`__TEXT,__dm<mod>x0` / `__DM<mod>W,__img` / `__TEXT,__dm<mod>x1` 三段式聚合段 | `dm/ios/tools/gen_embed.py`（不改，同样的 embed.S 进一个 dylib target 而不是可执行文件） | 今天这些 section 在主可执行文件里（`loader.c:473-476`） |
| `__DATA,__dm_nro_tab` + 三个共享 NRO 段（有 NRO 的游戏，如任天堂明星大乱斗 98 个） | `gen_embed.py`（不改） | `loader.c:485-492` |
| `Info.plist`、`Resources/dm/`（`*.fixups.tsv`、`*.gates.tsv`、`nro.tsv`、shader 表） | `build_ipa.sh:75-81` 的复制清单原样搬进 framework | 今天在 App 的 `dm/` 资源目录（`project.yml` `Gen/dm` resources） |
| `Resources/profile.tsv`（运行时 game profile，可选，优先用 Documents 里的） | `dm/games/game.py profile <id> <out>`（`game.py:192-232`） | 今天靠 DM_PROFILE 环境变量指向 |

framework 里**没有**宿主代码、没有 ObjC 类、没有入口函数——它对 dyld 是一个"加载后不被调用"的镜像，
唯一用途是让它的段被签名映射进进程，然后 `vm_remap` 到 guest 布局。romfs / msl / save / pso 一概不进
framework（数据不是代码，走 Documents，见 1.3）。

**方案 FH（备选）：framework = 整个 dmhost + 该游戏的聚合段。** 入口
`int dmgame_main(int argc, char **argv, const char *profile_path)`（= 现在的 `dm_main`，`main.m:11` 用
`-Dmain=dm_main` 编进宿主，framework 内同名导出），壳 dlopen 后 `dlsym(handle, "dmgame_main")` 调用。
仅当 FR 的探针（第 5 节 R1）失败时退到 FH。FH 的代价：宿主对象码每个游戏重复一份（dm/host 的
.c/.m 源码合计约 11,265 行，头文件另计——重复是浪费但量级可接受）。**更严重的是壳与 framework
各持一份 ObjC 类**（`front_ios.m` 的 App/SceneDelegate、Metal NVN 层的类），同名类跨镜像重复注册
是 ObjC 运行时的已知雷区，除非"壳里不放宿主"，但这又把窗口/Metal 生命周期切成两半。

### 1.2 入口符号设计（两种方案统一写法）

FR 下"入口"在壳里，签名不变：

```c
int dm_main(int argc, char **argv);          // dm/host/main.c，现状
// C 里的调用方式（壳内）：
//   argv[0] = "dmhost"
//   argv[1] = <选中 framework 的 Resources/dm>   ← loader.c read_layout 按目录读 <mod>.fixups.tsv（loader.c:185-186）
//   argv[2..] = 模块名，或省略让 profile 的 modules 生效（main.c:96）
void *h = dlopen(".../Frameworks/<game>.framework/<game>", RTLD_LAZY);
// 取镜像头传给 loader（两条等价路径，选一）：
//   a. void *marker = dlsym(h, "dmgame_image_marker");   // 3.2 的占位符号
//      Dl_info info; dladdr(marker, &info);               // info.dli_fbase = 该 framework 的 mach header
//   b. dlinfo(h, RTLD_DI_LINKMAP, &lm) → lm->l_addr
//   dm_set_image_header(info.dli_fbase)        ← loader.c 唯一实质改动：IMAGE_MH 从 &_mh_execute_header（loader.c:484）
//                                                 改为按游戏参数化；getsectiondata 对任意 mach header 可用
```

FH 下的框架入口（备选才需要）：

```c
// 每个 framework 导出（壳不重复定义，无符号冲突；两游戏 framework 永不同时 dlopen，见第 5 节 R4）
int dmgame_main(int argc, char **argv, const char *profile_path);
```

`profile_path` 参数是多余的——`hle_profile.c:211-215` 的加载顺序是"编译期默认 → DM_PROFILE 文件 →
DM_PROF_* 环境变量"，壳把 DM_PROFILE 设为
`Documents/games/<id>/profile.tsv`（没有就退到 framework 的 `Resources/profile.tsv`）即可，不需要新参数。
这一点 `hle_profile.h:1-6` 的注释写得很清楚：一个无 DM_PROFILE 的构建行为与编译期完全一致——
所以壳对任何 framework 用同一套入口代码。

### 1.3 壳如何设置环境并启动（全部复用现有开关）

`dm/ios/Sources/main.m boot_env()`（55-121 行）已经是完整的模板，C 只是把它从"编译期单游戏"改成
"选中游戏参数化"。逐项对照：

| 环境变量 | 现状（main.m 行号） | C 中的值 |
|---|---|---|
| `DM_ROMFS` | 87-90：`Documents/games/<DM_GAME_ID>/romfs` → `Documents/romfs` → `<App>/romfs` | `Documents/games/<选中 id>/romfs`，判定函数 `romfs_dir_ok`（19-28 行）原样复用 |
| `DM_SAVE` / `DM_TEMP` | 95-104：`game_dir_for`（36-39 行）的 per-game 布局，`romfs` 落在游戏目录内才启用 | 同上，**按游戏隔离已经存在**，壳只换 id |
| `DM_MSL_DIR` | 107-111：**已优先 per-game `<gdir>/msl`**，退到 bundle `<App>/msl` | 不改逻辑，shader 库放 `Documents/games/<id>/msl/`（数据，不进 framework，见 1.1） |
| `DM_PSO_BUNDLE` | 115-116：只查 bundle `<App>/pso` | 壳扩展为先查 `Documents/games/<id>/pso`（pso 离线管线档案是数据，BotW 一档约 650 MB/架构，`build_ipa.sh:82-86`） |
| `DM_NVN_SHMAP` | 105-106：bundle `<App>/dm/shader_map.tsv` | `<framework>/Resources/dm/shader_map.tsv` |
| `DM_PROFILE` | hle_profile.c:213-214 读取，iOS 侧今天没人设它 | `Documents/games/<id>/profile.tsv` 优先，退 framework 资源 |
| `DM_LANG` / `DM_SHOW_FPS` | 84-86（Info.plist `DMLanguage`） | 壳 Info.plist 或 Documents/env.txt（69-80 行的 env 文件机制不动） |
| 其余 `DM_*` 调试开关 | `main.c:42-46 flags_init` | Documents/env.txt，不变 |

启动路径：壳在 UIApplicationMain 之前不知道选哪个游戏，所以 `dm_host_preload_start`（main.c:118，
main.m:119 的 UIKit 并行加载）挪到"点选游戏之后、建窗口之前"调用——顺序仍是 main.c:115-117 注释
要求的"环境变量已设好、参数一致"。

---

## 2. 与架构 B 的真实差异，以及 iOS codesign 下的诚实结论

### 2.1 规则本身：iOS 只让 dlopen 签名 bundle 内的代码

三条证据链，从官方到实测到社区：

1. **Apple DTS 的书面答复**（Quinn "The Eskimo!"，developer.apple.com/forums/thread/773210）：
   *"While iOS does support `dlopen`, you can only open a library that's either built in to the OS or
   embedded within your app. ... The iOS security model is actively trying to prevent you from doing
   exactly what you're trying to do."* 该帖同一实验链还确认：同一个 dylib 放进 app bundle 能 dlopen，
   放 Data 容器不行。
2. **实测复现**（johnno1962/InjectionNext issue #81，2025-08 起）：同 TeamIdentifier 签名、合法
   load commands、甚至 get-task-allow + Developer Mode 的 dylib，只要在 bundle 外（Data 容器），
   `dlopen` 报 `code signature invalid (errno=1)`，拷进 bundle 后立即成功。结论：AMFI 拒绝的是
   **代码所在的路径**，不是签名的对错。该 issue 还确认 dylib **不能携带自己的 entitlements**。
3. **嵌入位置的官方要求**：TN2435（Embedding Frameworks In An App）与
   developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle——第三方 app 的动态
   framework 必须嵌在 app bundle 的 `Frameworks/` 内并由外层签名封存（CodeResources 列出每个嵌套二进制）。
   改动 bundle 内容 = CodeResources 变了 = 必须整体重签。

**反例为什么不算数**：LiveContainer（github.com/LiveContainer/LiveContainer）确实做到了"装一次壳、
之后随便加 app"。它的做法（读源码确认）：guest 可执行文件放在数据容器里，靠
`dlopen` 直接加载（`LCBootstrap.m:570-583`），能这样做的条件是
`"If JIT is enabled, bypass library validation so we can load arbitrary binaries"`（`LCBootstrap.m:367-371`）——
即持有 JIT/动态代码签名资格时，在**自己进程内** hook dyld：`mmap` 被换成"把文件读进匿名内存再
mprotect 成 exec"、`fcntl(F_ADDFILESIGS_RETURN)` 被改成谎报签名覆盖全文件
（`dyld_bypass_validation.m`，基于 xpnsec 的 Restoring Dyld Memory Loading，
blog.xpnsec.com/restoring-dyld-memory-loading）。README 明说：
*"(Below iOS 26) When JIT is available, codesign is entirely bypassed ... Otherwise, your app will be
signed with the same certificate used by LiveContainer"*——没有 JIT 就退回"ZSign 用壳自己的证书重签
guest"。我们的项目**不采用这条路**：JIT 资格（get-task-allow / 动态代码签名）在侧载调试场景技术上
拿得到（DolphiniOS 等靠 JIT-enabler 应用按会话附加），但那要求用户每次会话先跑一个 enabler、且整个
加载器建立在进程内 hook dyld 之上——LiveContainer 自己的代码就是"每次系统更新都可能断"的证词
（README 注明 "(Below iOS 26)"，即 iOS 26 起该路径有变，`LCBootstrap.m:577-583` 为 iOS 27 另加
`bypass_seg_count_check`）。我们只需要"映射已签名页"，从来不需要"执行未签名代码"，
loader.c:473-476 的 vm_remap 路线不依赖任何特殊资格。**所以 LiveContainer 证明的恰恰是规则的坚硬，
不是豁口：绕过它需要 JIT 资格 + dyld hook，二者我们都不具备也不想要。**

### 2.2 诚实结论：加游戏必须重签整个 bundle

推演：加一个游戏 = 加一个 framework = bundle 树变化 = CodeResources 变化 = 安装时的签名失效 =
**重新签名整个 app 并重装**。侧载场景（AltStore/SideStore）本来就是每次刷新都整体重签
（SideStore FAQ：同 bundle id 重装，Documents 数据保留），所以"重签"对用户不是额外流程，
但对**分发者**是：每次加游戏要出一个新 IPA，用户下载整个 IPA 重装。

因此 ROADMAP 第 123 行的 **"C: unbounded" 是错的，本文推翻它**。正确表述：

- **代码维度**：games per IPA 仍由体积上界（第 5 节 R3 的同一套算术：每游戏 modules 约 104 MB，
  ROADMAP:116，系统对超大包拒绝安装，`build_ipa.sh:170-172` 记录了 PackageExtractionFailed），
  ROADMAP:117 "4–8 games" 的估计对 B 和 C 同样成立。
- **数据维度**：romfs / msl / save / pso / profile.tsv 全是数据，放 `Documents/games/<id>/`，
  用户手动放文件即可、永不触发重签——这一维才是 unbounded，而且**架构 A 已经拿到了它**
  （WORK-IN-PROGRESS.md:41-44，`main.m` per-game 布局已实现）。
- C 的 "unbounded" 只在一种意义下接近成立：**给壳增加第 N 个游戏的边际工程成本不随 N 增长**
  （B 的聚合段和 255 section 预算是全体游戏共享的，见 2.3）。这是工程成本上的"无上界"，
  不是运行时能力上的。

### 2.3 那 C 相对 B 还值不值？值什么

B（4–8 游戏聚合进一个二进制，WIP C5 估 3–4 周）：所有游戏的模块 section 挤进同一个 Mach-O，
共享 255 section 预算与命名空间。ROADMAP:112-115 记录了实测事故：*两个游戏同名模块静默合并进同一
section，无任何报错（第二个游戏的代码消失了）*，NRO 式"3 共享段 + (game, module) 键表"是修补，
验证到 2 游戏 × 2 模块。C 把每个游戏放进自己的 Mach-O：

| 维度 | B（聚合二进制） | C（壳 + 每 game framework） |
|---|---|---|
| section 预算 | 全体游戏共享 255（`loader.c:485`："a Mach-O file has at most 255 sections"，SSBU 98 NRO ×3 段 = 294 已单游戏爆表） | **每 framework 各自 255**，同名 section 物理上不可能跨游戏合并——B 的静默合并 bug 在 C 里结构性不存在 |
| 增量构建 | 加/换一个游戏 → 整个巨型可执行重链接 | 只有该游戏的 dylib 重链接，壳二进制不变，`pack_ipa.py` 按文件指纹复用旧 IPA 条目（pack_ipa.py:12-15），换一个游戏的重打包接近增量 |
| 故障半径 | 任一游戏的段/链接问题让整个 IPA 构建失败 | 坏的 framework 让 `dlopen` 返回 NULL（壳弹一条错误继续），其余游戏不受影响 |
| 宿主份数 | 1 | 1（FR 方案） |
| 每游戏元数据 | 聚合表 | framework 自带（Resources + 段），分发单个游戏 = 拷一个目录 |
| 按需组合 | 每次都要全量决定装哪几个游戏 | 聚合脚本按用户拥有的 NSP 挑 framework 组装 IPA（仍是装时定死） |
| 工作量 | 3–4 周（WIP C5） | 本文第 6 节估 ~4 周 + 探针门 |

结论：**C 的定位是"B 的更干净实现"，不是"B 之外的第三种能力"**。如果 4–8 游戏一 App 值得做
（WIP C5 的悬而未决问题），C 用大约相同的成本把 B 的两个结构性风险（静默合并、全量重链）消掉，
外加按游戏分发的毛坯。若只要单游戏，A（1 周）仍然是正解，C/B 都不需要。

---

## 3. 构建系统怎么改

### 3.1 现状

`scripts/build_ipa_from_nsp.py`（NSP → IPA 全流水线）末段调 `dm/ios/tools/build_ipa.sh`：
生成 `Gen/`（`gen_build.py` 收集宿主源码、`gen_embed.py` 产 embed.S，build_ipa.sh:70-76）→
`xcodegen` 出单 target 工程（project.yml）→ `xcodebuild` 不签名构建（build_ipa.sh:138-143）→
占位 ad-hoc 签名 + entitlements（147-161 行，注释解释了为什么必须先有一个签名：侧载器要读它要替换
的 entitlements）→ `pack_ipa.py` 按 `archive path=source dir` 映射打包（166-188 行）。
一个游戏一次产出一份 IPA。Mac 侧的对应物是 `dm/mac/pack_app.py`：先签内层（`Contents/MacOS/dmhost`）
再签 bundle（pack_app.py:100-106），注释说明 hardened runtime 为何不可用。

### 3.2 `--framework` 模式（build_ipa.sh / build_ipa_from_nsp.py）

- 工程模板加一个 `framework` target（xcodegen `type: framework`，platform iOS），sources 只含
  `Gen/embed.S` + 一个 3 行的占位 `.m`（给镜像一个符号，供 `dladdr` 取 `dli_fbase`）+ `Info.plist`。
  `Gen/dm` 表格进 `Resources`。`gen_build.py` 不动（宿主源码归壳的 target），`gen_embed.py` 不动。
- 链接 flags：沿用 embed 的 `-Wl,-segprot,__DM<mod>W,rw,rw`（gen_embed.py 末尾输出），dylib 同样接受。
- 产物：`<game>.framework/`（dylib + Info.plist + Resources/{dm 表格, profile.tsv, launcher.json, icon}），
  外加一个 `game.manifest.json`（title id、名称、版本、modules 列表、chain 版本 `b-$V`、romfs marker——
  全部来自现有 `gp` 读取，build_ipa.sh:21-31）。
- chain 版本一致性：`DMSH_CHAIN` 全仓库单版本（build_ipa.sh:53 注释 "one version for every game"），
  聚合时校验所有 framework 的 manifest 同 chain，否则拒绝组装——今天 stage_resources.sh 对单游戏做的
  同类检查（stage_resources.sh:21-28）。
- 签名：`codesign --force --sign -` 占位 ad-hoc 签 framework（与 build_ipa.sh:158 现在签 App 的理由
  相同：侧载器要从占位签名里读 entitlements 并全部重签）。**framework 不带 entitlements 文件**
  （dylib 无法持有 entitlements，见 2.1 证据 2，内存权限等 entitlement 全在壳上，build_ipa.sh:119-124）。

### 3.3 壳 App 与聚合 IPA

- 壳是新的小 target：SwiftUI（游戏网格 + 设置，复用 `dm/ios/Sources/LauncherSettings.swift` 的做法），
  宿主源码经 `gen_build.py` 链入（`-Dmain=dm_main` 保持，入口改由壳内调用）。
- 聚合 = 新脚本 `dm/ios/tools/pack_launcher_ipa.py`（或 build_ipa_from_nsp.py 的 `--aggregate`）：
  输入壳 .app + N 个 `<game>.framework`，映射进
  `Payload/Shell.app/Frameworks/<game>.framework`，壳资源映射照旧，调 `pack_ipa.py` 产出一份 IPA
  （`--skip $P/_CodeSignature` 的既有跳过逻辑沿用，build_ipa.sh:188）。
- **签名顺序**（对照 pack_app.py:100-106 的"先内后外"）：
  1. 每个 framework 内 dylib，
  2. 每个 framework bundle（封存其 Resources 与 Info.plist），
  3. 壳可执行文件（带 entitlements，ad-hoc 占位），
  4. 壳 bundle（封存 Frameworks/ 下全部嵌套代码）。
  壳 bundle 的签名会把所有 framework 的 CD hash 写进 CodeResources——这正是"加游戏必须重签"的
  机械原因（2.2）。侧载器（SideStore/AltStore）安装时对每个嵌套二进制重签并重建外层封存：
  现有单二进制流程已依赖"侧载器重签并搬运 entitlements"（build_ipa.sh:147-158 注释），而
  LiveContainer 的 IPA 本身就装着 `Frameworks/LiveContainerSwiftUI.framework` 等嵌套二进制、
  经 SideStore 安装可用——嵌套代码会被重签的旁证。
- `pack_ipa.py` 复用：framework 各自是独立映射目录，指纹（size/mtime/ctime/inode，pack_ipa.py:193-195）
  使"换一个游戏重打包"只写变化的 framework——这是 C 增量性的落点。

---

## 4. 运行时选择器（壳的 UI 与数据来源）

- **游戏列表** = 扫描两个来源后按 title id 连接：
  1. **代码**：`Bundle.main/Frameworks/*.framework`，读每个 framework `Resources/game.manifest.json`
     （构建时生成，第 3.2 节），运行期用 `getsectiondata`/段存在性做交叉校验（防 manifest 与段不一致）。
     不建议扫数据文件当列表依据——romfs 是用户可移动的数据（外置盘是计划能力：当时设想按分片
     pread，天然支持外部路径，但今天 `main.m romfs_locate` 只查 per-game/Documents/bundle 三处，
     文件夹选择器是待办，ROADMAP:129-132），代码在不在 bundle 里才是"装没装"。
  2. **数据**：`Documents/games/*/`，"这个目录是不是一个游戏的文件"的判定已经存在：
     `main.m:19-28 romfs_dir_ok`（有 profile 的 `romfs_marker` 路径即算；旧的 `romfs.idx` 分片归档已不再读取）。
  - 列表状态：代码+数据 = 可玩，只有代码 = 提示"把 romfs 放进 Files"，只有数据 = 灰显"IPA 里没有这个游戏
    的 framework（需要重签安装）"——这条提示就是 2.2 结论的用户可见面。
- **存档隔离**：已经有了。`Documents/games/<id>/{save,temp}`，`main.m:95-104`：
  romfs 落在游戏目录内才用 per-game save（`per_game = [romfs hasPrefix:gdir]`，98 行），
  壳不改这个规则，只把选中的 id 传给 `game_dir_for`（36-39 行）。WIP:41-44 与 ROADMAP:125 的
  "A 已交付 per-game 布局" 即此。
- **profile 与设置**：`DM_PROFILE` 指向 `Documents/games/<id>/profile.tsv`（用户可改，不重签），
  无则退 framework 资源，`DM_PROF_*` 与 `DM_FPS_TARGET` 等开关的优先级链不变
  （hle_profile.h:3-5、hle_profile.c:211-219）。设置 UI 用壳自己的 launcher.json（每 framework 自带一份，
  `build_ipa.sh:96-97` 的 settings.py 产物搬进 Resources）。
- **切换游戏**：一次进程只跑一个游戏（理由见 R4）。游戏退出回壳 = 若宿主能干净收尾
  （hle_lifecycle 的 SIGTERM 路径）就回 shell 场景重建选择器，收不干净就 `exit(0)` 由用户再点图标
  （与 Switch 回 home 的手感一致）。两种都先写进壳，探针阶段一并验证。

---

## 5. 风险清单（每条：风险 → 证据 → 缓解/验证方式）

- **R1 `dlopen`/`vm_remap` 在 dylib 上是否成立——C 的存在性风险，探针先行。**
  规则层面 2.1 已定（bundle 内可 dlopen），但我们的用法有两个未验证细节：dyld 是否接受带多个
  `__DM*W` rw,rw 自定义段 + 上百 section 的 dylib，`vm_remap` copy=FALSE 把 **dylib**（而非主可执行文件）
  的已签名 __TEXT 页重映射到匿名地址再执行是否被 AMFI 放行。现行机制对"主可执行文件自己的段"成立
  （loader.c:473-476，注释并援引 libffi trampoline table 先例），dylib 与它在内核路径上是同一类
  （同进程内已映射的签名页），但**没有实验前不下结论**。探针必须先跑。
  说明：任务输入里提到 `dm/ios/probe/` 正在另一分支验证——**本工作树核对过 launcher-b、pr17、pr18、
  mg-profile-runtime 四个分支，`dm/ios/probe/` 尚不存在**（只有 `dm/gfx/metal/probe/` 与 `dm/host/probe.c`），
  全仓库也没有任何 dlopen 引用。本文第 6 节把它列为第一步交付物，实验清单：
  P1 设备上 dlopen 一个 100 MB 级自定义段 dylib，P2 对其 __TEXT 段 vm_remap copy=FALSE + 执行 +
  与现行 executable 路径逐字节对比，P3 `getsectiondata(dylib_mh, ...)`，P4 dlopen 失败的错误面
  （能否继续跑），P5 iOS 26 实机 + 侧载签名链（SideStore）各跑一遍。
- **R2 255 section 限制**：C 的每 framework 独立预算消掉 B 的跨游戏合并事故（2.3）。单游戏内
  NRO 过多仍沿用共享段方案（`gen_embed.py` 注释：最多 255 sections、SSBU 98 NRO×3 段必须打包，
  `loader.c:485-492`）。残余风险：壳自身 + framework 数量不影响各镜像预算（预算是 per-Mach-O 的）。
- **R3 体积**：每游戏 framework ≈ modules（约 104 MB 原始，ROADMAP:116）+ 表格，IPA 总体积 = 壳
  （~11 K 行宿主 + SwiftUI，数 MB 级）+ N × framework。压缩后估每游戏几十 MB（deflate 对 NSO 镜像
  的实际收益待测，无历史数据，标待验证）。shader 库（BotW 阴影库 344 MB，ROADMAP:116）、pso 档案
  （~650 MB/架构，build_ipa.sh:86）全部走 `Documents/games/<id>/`，不占 IPA。系统对过大的包拒绝安装
  （build_ipa.sh:170-172），这是 4–8 上界的最终来源。
- **R4 内存与 entitlement**：framework 不能持有 entitlements（2.1 证据 2），`increased-memory-limit`
  只需要加在壳上（build_ipa.sh:119-124 现有做法）。运行时 profile 让内存布局全部运行期可配
  （hle_profile.h:22-23 的 mem_reserve/alias/stack/pool 等），不同游戏不需要不同签名资格。
  **同一时刻只加载一个 framework**：规避跨镜像 ObjC 类重复与 C 符号串扰，也把"多游戏同时运行"明确
  划出范围（那是 LiveContainer 的多容器问题，不追）。内存上多装几个游戏不吃亏：未 dlopen 的
  framework 不映射任何页，dlopen 后的代码页经 vm_remap copy=FALSE 与原映射共享物理页
  （loader.c:475 "sharing the same signed pages"），不因加载翻倍，切游戏先终止当前进程（第 4 节），
  不存在两份 guest 内存布局并存。
- **R5 dyld 行为随 iOS 版本漂移**：LiveContainer 在 iOS 26 有豁免分支、iOS 27 加段数补丁（其源码
  2.1 节引用处），我们目标就是 iOS 26+（project.yml `deploymentTarget: iOS 26.0`）。探针必须在
  实际目标 OS 上做，并把这个探针纳入每次大版本升级的回归清单。
- **R6 打包与增量**：`pack_ipa.py` 复用按指纹（pack_ipa.py:12-15、193-195），framework 拆映射后
  增量成立，但 ad-hoc 重签会改变 dylib 字节 → 每次聚合后所有 framework 的指纹都会变（签名写入
  Mach-O）。缓解：聚合脚本对"构建产物 → 占位签名 → 打包"全程用固定副本，只有真正重建的 framework
  走签名，重签发生在设备侧（侧载器），不影响构建机增量。此项需要在 W4 实测确认。

---

## 6. 工作量分解（按周，◇ = 依赖探针结果，∥ = 可并行）

| 周 | 内容 | 依赖 |
|---|---|---|
| W1 | `dm/ios/probe/`：P1–P5 实验（新目录，本工作树四分支均无现成探针）| 无。3–5 天 |
| W1 ∥ | `--framework` 构建模式（build_ipa.sh 分支、xcodegen framework target、manifest 生成），Mac 上可先用普通 dylib 验证段布局与单测 | 不依赖探针（纯构建侧） |
| W1 ∥ | `loader.c` IMAGE_MH 参数化 + 宿主单测（Mac 可跑：map_image 的非 NRO 路径换成"给定 mach header"）| 不依赖探针 |
| W2 ◇ | 壳 App：选择器 UI（扫描 Frameworks + Documents/games）、env 装配（第 1.3 节表）、dlopen→dm_main 接线，探针若失败则切 FR→FH（第 1.1 节）或终止 C | W1 探针 P1–P3 |
| W3 | `pack_launcher_ipa.py` 聚合 + 签名顺序 + `test_pack_ipa.py` 扩展，双游戏 IPA 在模拟器/设备装机链验证 | W2 |
| W4 ◇ | 实机端到端：两个真实游戏（探针用的 NSP 复用）、切游戏、存档隔离、坏 framework 容错、R6 增量实测、文档收尾 | W3 + 用户的 NSP |
| 缓冲 | R5 的 iOS 26.1/27 差异回归、FH 备选路径（若 P2 失败，+1 周实现 FH 的 dmgame_main 与壳移交）| — |

总计：**约 4 周到"双游戏可玩"，探针失败再 +1 周（FH）或止损回 B**。与 B 的 3–4 周相比没有省，
买到的是 2.3 表里的结构性收益，决定点仍建议放在 W1 探针之后。

---

## 7. 证据来源汇总

仓库内（文件:行号见正文）：
- `dm/host/loader.c:473-476`（iOS 嵌入与 vm_remap/libffi 先例）、`:485-492`（255 section 与 NRO 打包）、
  `:185-186`（fixups.tsv 运行期按目录读取）、`:252`（gates.tsv）
- `dm/ios/tools/gen_embed.py:1-13`（三段式段、ITMS-90999 单可执行段、NRO 共享段 + 表）
- `dm/host/main.c:42-46,87-97,115-124`（DM_* 开关、模块清单来源、preload 约定）
- `dm/ios/Sources/main.m:19-28,36-39,41-52,69-80,87-116`（per-game 布局、romfs 判定、env 装配全表）
- `dm/host/hle_profile.{h:1-6, c:211-219}`（运行时 profile 加载顺序），`dm/games/game.py:192-232`（profile TSV 生成）
- `dm/ios/tools/build_ipa.sh:53,70-76,96-97,100-101,117-124,138-161,166-188`（chain 版本、Gen 生成、
  entitlements、不签名构建、占位签名、pack 映射）
- `dm/ios/tools/pack_ipa.py:12-15,193-195`（指纹复用），`dm/ios/tools/stage_resources.sh:21-28`（chain 校验先例）
- `dm/ios/project.yml`（iOS 26.0 target、Gen/dm resources、`-Dmain=dm_main`）
- `dm/mac/pack_app.py:100-106`（先内后外签名先例）
- `dm/host/dm.h:11`（MAX_MOD 128：profile 模块 + NRO 上限）
- `docs/ROADMAP.md:109-127`（调查结论、255 合并事故、104 MB/游戏、A/B/C 表），`docs/WORK-IN-PROGRESS.md:41-47,61,63`（A 现状、C5/C7）

仓库外：
- Apple DTS（Quinn "The Eskimo!"），dlopen 规则：developer.apple.com/forums/thread/773210
- InjectionNext 实测（bundle 外同 TeamID dylib 被拒、dylib 无 entitlements）：github.com/johnno1962/InjectionNext/issues/81
- TN2435 嵌入 framework：developer.apple.com/library/archive/technotes/tn2435/_index.html，
  Placing content in a bundle：developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
- LiveContainer（JIT 条件下的 dyld 验证绕过、无 JIT 则重签 guest、iOS 26/27 适配）：
  github.com/LiveContainer/LiveContainer（README，`LiveContainer/LCBootstrap.m`、`LiveContainer/dyld_bypass_validation.m`）
- SideStore FAQ（重装同 bundle id 数据保留、重签模型）：docs.sidestore.io/docs/faq，
  免费 Apple ID 3 app / 10 App ID 限制：faq.altstore.io（这也是"所有游戏进一个壳"的动机之一）

> **Update (merged):** the dlopen probe now exists — `dm/ios/probe/` with `build_probe.sh`, committed alongside this document, and `probe-out/DmProbe.ipa` is built. W1 step 1 is done. What remains is running it on an iOS 26 device and reading `Documents/probe-log.txt`.
