# 虚拟手柄布局编辑器 — 上游记录

- **上游 PR**: seedds/nxnative#811（2026-11-01 开出，等待上游 review）
- **本地补丁**: `patches/0036-…`（同内容，`Upstream-Status: pending`）
- **开发过程**: 主会话初版（2026-10-31）→ 子会话 PadHarness 测试壳 + 修复 iOS 26 Scene 生命周期闪退 + 三项增强（ABXY 独立调整、一键复位、触摸命中与绘制同源）→ owner 真机验收（iPhone 17 Pro Max）→ 折叠为单个提交提上游
- **适配上游**: 上游已把 `dm_profile()->pad_layout` 改为宏 `DM_GAME_PAD_LAYOUT`，上游版已随之适配
- **姊妹 PR**: seedds/nxnative#788（3D 布局右摇杆提示，本地补丁 0035）
- **测试壳**: `~/ZCodeProject/pad-harness/`（不在本仓库；交接文档 HANDOFF-PADHARNESS-2026-10-31.md）
- 注意: 0036 历史上裹挟了 0001 的部分内容与 0041 的文件（迁移折叠时代形成，`check` 因容错未报）；#230 移植时应一并清理补丁队列
