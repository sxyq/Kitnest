# 10-需求

当前需求与规格。**NN-规格-<模块>.md 是需求基线**（原版逆向测绘出的行为规格 = 重建的验收标准），
与源码同步维护；新增文档前先看 [`00-总览/工程结构与构建.md`](../00-总览/工程结构与构建.md) 第 7 节的三道门槛。

## 目录

| 位置 | 内容 | 权威性 |
|---|---|---|
| `NN-规格-<模块>.md`（03–21） | 各子系统行为规格：界面规则、交互约定、数据语义、问题记录 | **当前权威** |
| `11-补全规格总纲.md` | 总纲与补全原则 | 当前权威 |
| [`逆向测绘/`](逆向测绘/) | 01-功能树与逆向映射总览、02-源码级测绘报告 | **证据属性**：原版逆向规格保留证据，不直接当作当前实现 |
| [`对标参考/`](对标参考/) | ArcZip（立项/集成/用例/归档对齐）、对标（三项目/工具箱/压缩包）、1Capture（交互特色/落地对照/图帘对照） | 参考：结论以代码为准 |
| [`规划项/`](规划项/) | 个性化设置、悬浮剪贴板、传输与互传（LinkSwift/投屏重构/互传联盟/窗口识别） | 参考：未落地标注「待做」 |

## 模块 → 规格对照

| 模块 | 规格 | 源码说明 |
|---|---|---|
| 监测区 / 状态栏 / 菜单栏 | 03、08 | [20-源码实现/Features/Monitor/](../20-源码实现/Features/Monitor/模块说明.md)、[StatusBar](../20-源码实现/Features/StatusBar/模块说明.md)、[FrsetStatsBar](../20-源码实现/FrsetStatsBar/模块说明.md) |
| 主面板 | 04、12 | [20-源码实现/Features/Panel/](../20-源码实现/Features/Panel/模块说明.md) |
| 剪贴板 | 05、14 | [20-源码实现/Features/Clipboard/](../20-源码实现/Features/Clipboard/模块说明.md) |
| 截图与 OCR | 06、15、16 | [20-源码实现/Features/Capture/](../20-源码实现/Features/Capture/模块说明.md) |
| 设置窗口 | 07、18 | [20-源码实现/Features/Settings/](../20-源码实现/Features/Settings/模块说明.md) |
| AI 体系 | 09 | [20-源码实现/Features/AI/](../20-源码实现/Features/AI/模块说明.md) |
| 工具箱 / 快捷键 / 其余子系统 | 10、19 | [20-源码实现/Features/Toolbox/](../20-源码实现/Features/Toolbox/模块说明.md) |
| 统计窗 / 权限引导 | 17 | [20-源码实现/Features/Onboarding/](../20-源码实现/Features/Onboarding/模块说明.md) |
| 菜单栏通知条与彩蛋 | 13 | [20-源码实现/Features/StatusBar/](../20-源码实现/Features/StatusBar/模块说明.md) |
| 文件中转与网盘 | 21 | [20-源码实现/Features/TransferDock/](../20-源码实现/Features/TransferDock/模块说明.md) |
| 刘海岛 / 触觉 / 存储 / 录屏 | （暂无独立规格，行为以源码说明为准） | [Island](../20-源码实现/Features/Island/模块说明.md)、[Haptics](../20-源码实现/Features/Haptics/模块说明.md)、[Storage](../20-源码实现/Features/Monitor/Storage/模块说明.md)、[Recording](../20-源码实现/Features/Recording/模块说明.md) |

## 维护规则

- 规格的行为结论必须可被源码验证；与实现不一致时，先改规格（记录差异）再动代码。
- 问题记录写进对应规格的「问题记录」节，不单独建事件文档。
- 逆向测绘材料**保留证据属性**：引用时注明「原版行为」，不要写成「当前实现」。
