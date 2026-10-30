# 从源码构建

启动器（见 [README.zh-CN.md](README.zh-CN.md)）运行的就是终端里的这些脚本。本页是手动路线，给进阶用户、开发，或启动器用不了的时候：工具、你的 `prod.keys`，以及在终端里构建 IPA。英文版：[BUILDING.md](BUILDING.md)。贡献规则见 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)。

## 取得工具

归档功能不改变正常构建流程。按上游的 [README](https://github.com/seedds/nxnative) 安装 Xcode、
Homebrew 工具和 Python 包，然后打 IPA。

```bash
git clone https://github.com/<you>/NX2Apple.git
cd NX2Apple
brew bundle --file=Brewfile                       # xcodegen, zstd, spirv-cross, glslang（打包脚本会检查它）, .NET SDK
python3 -m venv .venv                             # Homebrew 的 Python 不允许全局 pip 安装（PEP 668）
.venv/bin/python -m pip install lz4 capstone fonttools zbic nsz "backports.zstd; python_version < '3.14'"
source .venv/bin/activate                         # 之后的 python3 即 venv 的（每个新终端都要执行）
```

`backports.zstd` 是《王国之泪》的 zstd 字典需要的，其他游戏用不到。

## 你需要准备的文件

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

密钥的导出方式在 Switch 自制软件社区有完整文档（常见做法是在破解机上跑 Lockpick_RCM）。
本仓库不涉及也不携带这一步。两条来自真实导出文件的实用提示：

- **格式错误的行。** 有的导出工具会写出十六进制值长度不对的行（真实案例：33 行长度错误的
  `master_kek_source_*`），解包工具会因此拒绝整个文件。删掉这些行，原文件留个备份。
- **更新包。** 更新 NSP 的 ticket 可能带比本体更新的密钥世代。解包工具直接从每个 NSP 内部的
  common ticket 读 title key，所以实际使用中只要 `prod.keys` 不算太旧，两份都能解开——这里
  实测过本体是世代 15、更新是世代 16，keys 文件只到 15，两个包都正常解出。

## 构建 IPA

主构建脚本**默认打瘦身 IPA**（不含 RomFS，因为 App 从设备上的 `Documents/games/<id>/` 读游戏数据），所以上面的构建
已经产出。以后只想重新打包时：

```bash
GAME=<title id> W=<工作目录> PATCHED=<改写目录> \
  ROMFS=<RomFS 目录> MSL_IOS=<shader 目录> \
  dm/ios/tools/build_ipa.sh <输出.ipa>
```

`--full-romfs`（或 `DM_FULL_ROMFS=1`）把 RomFS 打进包里——上游行为，只对小体量游戏有意义。

RomFS 不再需要先打成分片归档：构建会把游戏数据写成一个 `romfs.img`。更早做好的分片归档（`romfs.idx` 加 `romfs.00`、`romfs.01`……）不再被读取；启动器会把这样的文件夹视为没有游戏数据，需要再发送一次 `romfs.img`。
