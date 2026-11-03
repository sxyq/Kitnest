# ArcZip 接入 —— 立项材料对照表（2026-10-21）

> 需求文档：`temp/arczip/work/ArcZip接入FrsetNext-需求文档.md`（v1.0，已确认）
> 材料盘点：`temp/arczip/`（ArcZip-1.1.1-222.dmg + work/ 逆向档案）
> 方法：先对照已有立项材料；缺口处实施时按 REA 流程边逆向边补（Ghidra/
> dsdump 工具链在 tools/ 已就位，ArcZipUnlocked.app 可作运行时证据）。

## 一、材料清单（已具备）

| 材料 | 内容 | 覆盖需求 |
|---|---|---|
| ArcZip-1.1.1-222.dmg | 原版分发件（RE 主目标） | 全部（行为基准） |
| ArcZipUnlocked.app | 解锁版（Pro 全开）+ 运行截图 | M1 悬停预览运行时证据 |
| work/ArcZip-功能全景清单.md（328 行） | 功能全景 | FR 全量对照基准 |
| work/ArcZip-悬停预览机制剖析.md（180 行） | **五层流水线完整剖析**（追踪/控制/解码/展示/缓存） | **M1 全部**（FR-101~105） |
| work/ArcZip-开源依赖与FrsetNext接入评估.md（143 行） | 依赖选型评估 | 6.1/6.2（FR-801~805 依据） |
| work/ArcZip融入FrsetNext方案.md（352 行） | 融合方案 | 6.3 模块划分依据 |
| work/ArcZipReplica/（Swift 包） | 复刻工程（含 Package.swift/Sources） | UI 复刻参考 |
| work/assets/7zz + 许可文件 | **7zz 可执行件 + Sparkle/DSStore/Inter 许可** | M3/M8 直接可用 |
| work/strings_out/ | 提取字符串（main_strings/commerce_symbols） | 文案/商业化行为对照 |
| tools/（Ghidra 12.1.4 + dsdump） | 逆向工具链 | 缺口补证用 |

## 二、需求 ↔ 材料 ↔ 缺口 对照

| 模块 | 需求 | 材料状态 | 缺口（实施时补） |
|---|---|---|---|
| **M1 悬停预览（核心）** | FR-101~105 | ✅ **剖析文档完整**（五层/两段式/时序/缓存全解） | 无缺口；直接按剖析实施 |
| M2 归档浏览/解压 | FR-201~211 | ✅ 功能全景 + 方案有结构；7zz 在手 | 冲突策略/过滤细则按全景清单实施 |
| M3 创建压缩包 | FR-301~308 | ✅ 依赖评估给出分层（libdeflate/ZIPFoundation/7zz） | libdeflate 需随源码子集集成（arczip_ 前缀） |
| M4 归档内编辑 | FR-401~408 | ⚠️ 全景清单有功能面，**编辑交互细节（撤销栈/合并到最新版）缺剖解** | 实施时对 ArcZipUnlocked.app 做 REA 运行时对照（边做边逆向） |
| M5 访达右键 | FR-501~507 | ✅ Info.plist 声明可从 dmg 提取对照 | 需实测（验收 8.4） |
| M6 系统集成 | FR-601~604 | ✅ 33 扩展名清单（附录 A）明确 | LSSetDefaultRoleHandler 行为实测 |
| M7 工具箱/设置 | FR-701~703 | ✅ 方案有设置页结构 | — |
| M8 压缩引擎 | FR-801~805 | ✅ 依赖评估完整 | libdeflate 编译入 build.sh |

## 三、已落地（本轮 P0-c 核心）

- **FR-103 分级解码器**（`PreviewFileThumbnailLoader`）：
  图片→NSImage/ImageIO；PDF→CGPDFDocument 首页渲染；其余（Office/任意）→
  QLThumbnailGenerator 兜底（与 ArcZip 解码层同口径）
- **FR-105 缓存**：NSCache 60 张上限自动回收
- **FR-104 两段式观感**：先出系统图标、解码完成原位替换（无闪白）
- 剪贴板文件条目悬停预览从「路径列表」升级为**缩略图 + 文件名**（单文件 120pt 大图）
- QuickLookThumbnailing 框架已链入（build.sh）

## 四、后续实施顺序（按需求文档 §9）
- [x] P0-c 部分：文件悬停预览分级解码（v111）
- [x] **P0-a（v118）**：`ArchiveCore` 归档引擎（7zz 子进程封装：list / readEntry / extract / updateEntry / addFiles / removeEntries / create）
- [x] **悬停气泡内 ZIP 预览（v118 用户明确要求）**：`ArchivePeekView` 直接嵌在首页剪贴板悬停气泡的「文件」态里——列出归档条目（目录优先、前 8 条、图标/大小/压缩前后），**不弹新窗口**
- [x] **P1-a（v118）**：归档浏览窗口 `ArchiveBrowserWindow`（条目列表 + 搜索 + 文本编辑 + 图片/PDF/Office 预览 + 解压/添加/删除）
- [x] **P1-b 部分（v118）**：归档内文本编辑并写回（`7zz a` 保持包内路径；首次修改自动 `.bak` 备份）；Office 按 D1 只读预览
- [x] **Word/PPT 悬停预览（v118）**：气泡内 168pt 首页大图 + 「快速查看」（系统 QLPreviewPanel，可翻页看全文）
- [ ] P0-c 收尾：双 CALayer 交叉淡入（FR-104 动画层）
- [ ] FR-403 撤销/重做栈、FR-405 合并到最新版（需对 Unlocked.app 补 REA 对照）
- [ ] P0-b：工具箱两个工具 + 面板区段
- [ ] P1-c/d：访达右键 + 默认应用接管
- [ ] P2：UI 精细化（VariableBlur 等）

## 五、合规随记
- 7zz 以独立可执行文件分发（LGPL），附许可与源码链接义务
- unRAR 限制：不提供 RAR 创建入口
- 开源许可页须含 libdeflate/ZIPFoundation/Sparkle/DSStore/Inter 声明
