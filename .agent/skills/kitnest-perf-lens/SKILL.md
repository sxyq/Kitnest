---
name: kitnest-perf-lens
description: Kitnest 全链路性能/交互/渲染热点诊断；先独立读函数完整实现与调用链，再借鉴 fast-anything 方法，未确定的热点先要求本地隔离或既有数据测量。适用 screenshot、Island、Storage、Glass、Archive、Clipboard、FloatingBall、Monitor、GenieWarp。
---

# Kitnest Perf Lens — 本项目分析方法

## 不可覆盖的用户约束

用户使用电脑期间：**不抢鼠标、不变更前台焦点、不弹窗打断、不重启/终止 Kitnest**。不执行 `launch_smoke.sh`、`open -a`、`open -g`、会打开窗口的 `kitnest://` 深链、AX 点击、鼠标模拟、`pkill/kill`、会触发窗口的 `defaults probe`、启动会覆盖 `/Applications` 的 build.sh，也不自动清理缓存、推送 main、打 DMG。对于需要窗口操作的测量，注明「需用户空闲或单独授权」，先继续其他静态修复。分析工具只能对已存在的日志/源码或独立、无 UI 的纯函数负载使用。

## 使用 fast-anything 的准确边界

原版 Skill（相邻 `../fast-anything/SKILL.md`）针对 Python/Node/TypeScript/Ruby/Java/Go/PHP/C/C++/C# 的**纯函数**，流程为 scan→port→verify→enable→bench→report，不能自动识别 SwiftUI、AppKit、NSWindow、Metal/Core Animation 或 Swift 的业务行为。对 Kitnest 主程序 **不要**启动 `fast-anything` 或转换 Rust。只借鉴其方法：真实热点 → 可分离的纯计算 → 语义等价 → 端到端收益。若独立 Python/Node/C 工具脚本有代表性安全工作负载且函数占用明显，才考虑原版 CLI；CLI 会重新运行用户给的命令并记录真实调用，不能录制含机密的任务输入。

## 分析算法（每次任务必须走这一逻辑，不创建额外文档）

1. 独立观察：读真实本地 `git status/HEAD`、完整相关源码、父级调用者、数据结构、取消/缓存/刷新路径；别看摘要就定性；旧文档只用作定位。
2. 构造业务链：入口事件 → 状态 → 计算/IO → UI 发布/渲染 → 退出/取消/缓存失效。标出每个方法实际在哪个线程或队列、每次触发次数与副作用。
3. 明确区分：源码可证缺陷、性能热点候选、已有日志观察、缺设备/交互时不能确认的事项。
4. 对热点候选，若必须测量才知，先给本地 Agent 一个独立的**只读/无前台**测量包：具体方法、需要哪段计时、数据格式、如何避免系统行为变化；未获得数据前不臆测“快 xx%”。
5. 对源码已经能证明的语义缺陷，直接交付最小修复指令，不强制等性能测量。
6. 批量只修改当前目标相关职责，沿用原功能和数据模型；截图画质、UI、动画曲线、滑动、玻璃观感不准被“优化”删减。必要验证限于不会打断用户的编译/静态/纯函数检查。

## 高优先级真实检查点（以本地 HEAD 为准）

- `Core/Motion/MotionPacingProbe.swift` 的 CVDisplayLink 回调仅是显示时钟节奏，不是 app 实际提交/呈现的 FPS；`NSScreen.main` 与目标显示器可能不一致，快速反向时上一个窗口被中止；仅输出「显示链路回调」，不能说「零掉帧」。默认常开探针宜转为显式诊断开关。
- `Features/Monitor/Storage/StorageTreemap.swift:StorageMapShape.path(in:)` 在 2026-11-23 从跨区域弯曲轮廓改为地图列局部矩形上沿，违背用户要求的“曲线延伸到上半部”；单纯 0 未映射函数不能证明 UI 符合要求。
- `Core/UI/LiquidGlass.swift:GlassSurface/GlassTintOverlayView` 在 6aafe4eb 已经合并底衬+霜感为单层；**不得重复要求合并**。真正未解决的焦点问题在 `LiquidGlassMaterial.makeView` 26+ NSGlassEffectView 与 NSVisualEffectView `.inactive` 分支。
- `Features/Island/IslandController.swift` 局部点击置 `openedExplicitly=true`，`endInteraction` 不解除，检查离开不收起；`surfaceDidChange` 每帧的指针更新，`IslandSurface` 整块 `.compositingGroup()` 与遮罩布局成本。
- `Features/Archive/UI/ArchiveBrowserWindow.swift` 的 `children(in:of:)` 和 `columnTrail` 每列扫描全数组；可按 parent path 构建 children 索引并在 `reload()` 时失效，保留合成空目录和辅助文件过滤语义。
- `Features/FloatingBall/DesktopPetView.swift` 的 3fps `TimelineView` 每帧可执行 `NSImage(contentsOfFile:)`，自定义图需缓存并在配置/路径变化时失效，不能关掉动画。
- `tools/func_table.py` 的 `doc_path` 为路径最长前缀映射，**0 条未映射≠文档正确/函数调用关系正确**；重载只有 file#owner#name 粒度。`docs/20-源码实现/Features/Clipboard/模块说明.md` 仍写两栏，源码已经三栏。
- `AGENTS.md`、`.agent/skills/frset-release/SKILL.md`、`.agent/skills/frset-verify/SKILL.md` 仍有强制重启/探针弹窗命令，先修正规则再给 Agent 新任务。

## 回答结构

按需求分成**已查实的错误（给出文件/函数/修法）**、**需本机计时的瓶颈（测量要求与阈值）**、**本轮不动的已完成能力**。不要把 CVDisplayLink 回调、orderFront 返回、30fps 屏录、源码索引全绿当实际帧率/功能正确性的证据。
