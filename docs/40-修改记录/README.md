# 40-修改记录

按模块持续维护的修改记录。一个模块一份 `变更记录.md`，重要变更追加条目，完整历史以 git 为准。

> **不再按事件新增文档（2026-11-22 起，b974585）**
>
> 「今天干了什么」「某次事故复盘」「某个需求落地」都不单独建文档。
> 新产生的内容按归属并入既有文档：
> - 流程、发布、排障、启动纪律 → [`00-总览/开发工作流.md`](../00-总览/开发工作流.md)
> - 模块行为、界面规则 → `10-需求/NN-规格-<模块>.md`
> - 实现机制与调用链 → `20-源码实现/<代码路径>/模块说明.md`
> - 函数级结论 → [`00-总览/数据表/`](../00-总览/数据表/)（函数清单/台账/映射 CSV）
> - 窗口/浮层 → [`00-总览/数据表/预览窗口排查.csv`](../00-总览/数据表/预览窗口排查.csv)
>
> 对应关系与新增文档的三道门槛见 [`00-总览/工程结构与构建.md`](../00-总览/工程结构与构建.md) 第 7 节。

## 条目格式（每条修改至少记录）

```markdown
### <日期> <一句话结论>（<git 短提交号>）
- 需求/原因：（用户原话或根因）
- 涉及文件与关键函数：（仓库相对路径 + 类型/函数名）
- 修改后行为：（用户可感知的行为差异）
- 已确认结果 / 未确认事项：（实测方式与结果；没验的如实写「未确认」）
```

## 维护规则

- **跨模块变更**：在主要负责模块记录完整条目，其他模块写一行「另见 <模块>：<日期> <结论>（<提交号>」即可，不重复全文。
- **不能每做一次修改就创建一份新的事故报告、完成报告或执行总结**——条目追加到对应模块的 `变更记录.md`。
- **已有历史记录保留，不随意删除真实证据**：2026-11-23 之前的带日期一次性审计报告已归档到
  [`90-历史归档/审计报告/`](../90-历史归档/审计报告/)（只读）；`变更记录.md` 的「完整提交索引」节
  保留 `git log` 输出，根因细节用 `git show <提交号>` 复核。
- 新条目插在「重要变更条目」节顶部（时间倒序）。

## 模块 ↔ 源码 ↔ 文档对照

| 变更记录 | 源码路径 | 源码说明 |
|---|---|---|
| [Capture](Capture/变更记录.md) | `apps/FrsetNext/Sources/Features/Capture/` | [20-源码实现/Features/Capture/](../20-源码实现/Features/Capture/模块说明.md) |
| [Clipboard](Clipboard/变更记录.md) | `Features/Clipboard/` | [20-源码实现/Features/Clipboard/](../20-源码实现/Features/Clipboard/模块说明.md) |
| [Panel](Panel/变更记录.md) | `Features/Panel/` | [20-源码实现/Features/Panel/](../20-源码实现/Features/Panel/模块说明.md) |
| [Monitor](Monitor/变更记录.md) | `Features/Monitor/` | [20-源码实现/Features/Monitor/](../20-源码实现/Features/Monitor/模块说明.md) |
| [Storage](Storage/变更记录.md) | `Features/Monitor/Storage/` | [20-源码实现/Features/Monitor/Storage/](../20-源码实现/Features/Monitor/Storage/模块说明.md) |
| [Island](Island/变更记录.md) | `Features/Island/` | [20-源码实现/Features/Island/](../20-源码实现/Features/Island/模块说明.md) |
| [TransferDock](TransferDock/变更记录.md) | `Features/TransferDock/` | [20-源码实现/Features/TransferDock/](../20-源码实现/Features/TransferDock/模块说明.md) |
| [Settings](Settings/变更记录.md) | `Features/Settings/` | [20-源码实现/Features/Settings/](../20-源码实现/Features/Settings/模块说明.md) |
| [Onboarding](Onboarding/变更记录.md) | `Features/Onboarding/` | [20-源码实现/Features/Onboarding/](../20-源码实现/Features/Onboarding/模块说明.md) |
| [AI](AI/变更记录.md) | `Features/AI/` | [20-源码实现/Features/AI/](../20-源码实现/Features/AI/模块说明.md) |
| [Toolbox](Toolbox/变更记录.md) | `Features/Toolbox/` | [20-源码实现/Features/Toolbox/](../20-源码实现/Features/Toolbox/模块说明.md) |
| [Archive](Archive/变更记录.md) | `Features/Archive/` | [20-源码实现/Features/Archive/](../20-源码实现/Features/Archive/模块说明.md) |
| [StatusBar](StatusBar/变更记录.md) | `Features/StatusBar/` | [20-源码实现/Features/StatusBar/](../20-源码实现/Features/StatusBar/模块说明.md) |
| [Recording](Recording/变更记录.md) | `Features/Recording/` | [20-源码实现/Features/…](../20-源码实现/)（并入 Toolbox 说明） |
| [Haptics](Haptics/变更记录.md) | `Features/Haptics/` | [20-源码实现/Features/Haptics/](../20-源码实现/Features/Haptics/模块说明.md) |
| [FrsetStatsBar](FrsetStatsBar/变更记录.md) | `FrsetStatsBar/` | [20-源码实现/FrsetStatsBar/](../20-源码实现/FrsetStatsBar/模块说明.md) |
| [Core-UI](Core-UI/变更记录.md) | `apps/FrsetNext/Sources/Core/UI/` | [20-源码实现/Core/UI/](../20-源码实现/Core/UI/模块说明.md) |
| [Core-Motion](Core-Motion/变更记录.md) | `Core/Motion/` | [20-源码实现/Core/Motion/](../20-源码实现/Core/Motion/模块说明.md) |
| [Core-Runtime](Core-Runtime/变更记录.md) | `Core/Runtime/` | [20-源码实现/Core/Runtime/](../20-源码实现/Core/Runtime/模块说明.md) |
| [App](App/变更记录.md) | `apps/FrsetNext/Sources/App/` | [20-源码实现/App/](../20-源码实现/App/模块说明.md) |
