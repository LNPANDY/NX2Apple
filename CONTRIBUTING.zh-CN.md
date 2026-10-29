# 参与贡献

英文版：[CONTRIBUTING.md](CONTRIBUTING.md)（提 issue 要附什么、提 pull request 的规则、补丁队列都在那里）。在终端里手动构建（工具、`prod.keys`、IPA）见 [BUILDING.zh-CN.md](BUILDING.zh-CN.md)。下面是帮忙补充游戏。

## 帮忙补充游戏

每款新游戏都需要单独的 bring-up：profile（build ID、内存布局、纹理槽位）、必要时的 shader 读取器、
以及补丁点。**两种帮忙方式，都有用：**

- **报告一款能跑的游戏** —— 如果你让验证清单之外的游戏跑起来了，开 issue 附上 title ID、更新版本和
  你做的步骤，它会变成一个别人也能用的 profile。
- **提交缺失的着色器** —— 如果游戏能跑但首次使用某个效果时卡顿，说明它的 shader 变体不在映射表里。
  宿主可以导出找不到的部分（`DM_NVN_SHDUMP=<dir>`）。附上它们，我们把它加进 `shader_map.tsv`，
  所有人都受益。

带完整 `Documents/log.txt` 的 issue 会优先看——那份日志通常能直接指出缺的是什么。
