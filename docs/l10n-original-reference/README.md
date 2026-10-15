# 原作 L10n 键表（证据文件 / 仅作重建参考）

> ⚠️ **本目录内容来自逆向目标 App（Frset 1.3.12）的原始资源，不打包进 FrsetNext.app。**
> 它是「原作文案长什么样」的**证据留存**，供重建侧逐键比对与后续批量接入时查证，
> **不是** FrsetNext 的运行时资源。FrsetNext 实际打包的资源只有
> `apps/FrsetNext/Resources/**`（当前 19 键子集，见该目录）。
> 若误把本目录并入 app bundle，会把未消费的 774 键一并塞进产物——**请勿这样做**。

**本目录含 22 个语言的全表（各 793 键）**。逐语言校验表、空值键陷阱见 **`MANIFEST.md`**（扩展前必读）。

## 文件

本目录共 **22 个语言文件**（各 793 键）+ 本 README + `MANIFEST.md`。
逐语言键数/键集差异/sha256 见 `MANIFEST.md`。

| 文件 | 内容 | 键数 | 原作文件 sha256 |
|---|---|---|---|
| `en.Localizable.strings` | 英文表（基准） | **793** | `825b4982227243631365c3e14be0860601890a0a1b196a88bdf413e8f165d3a3` |
| `zh-Hans.Localizable.strings` | 简体中文表 | **793** | `15fc37221a78fb0d24df6c25a3ef361692939af4ca8651b09131f0c292160d44` |
| 其余 20 个语言 | `<lang>.Localizable.strings` | 均 **793** | 见 `MANIFEST.md` |

语言清单（22，与原作 `*.lproj` 目录一一对应）：
`ar de en es fr hi id it ja ko nl pl pt-BR ru sv th tr uk vi zh-Hans zh-Hant-HK zh-Hant-TW`

## 来源与抽取方法（可复现）

```
源：/Applications/Frset.app/Contents/Resources/{en,zh-Hans}.lproj/Localizable.strings
    （原作为 Apple 二进制 plist，29,120 / 33,242 字节）

plutil -convert json -o - <源文件>        # 二进制 plist → JSON
```

本目录存的是 **UTF-8 文本 `.strings`**（按键名字典序排列），而非原二进制 plist：
文本形态可 `grep`、可 `diff`、可被 `plutil -lint` 校验，更适合当参考件；
值与键面逐字保留，未翻译、未改写、未裁剪。

## 校验结论（本目录落盘时实测）

1. **键数**：en 793 / zh-Hans 793。
2. **键集完全一致**：`set(en) == set(zh-Hans)` 为真，双向差集均为空——
   印证 specs/18 §3.4「zh-Hans 与 en 键集完全一致，已批量比对」。
3. **逐键逐值全等**：将本目录两文件重新 `plutil` 回 JSON 与原作 JSON 做 `==` 全表比较，
   结果为 `True`（en 与 zh-Hans 各自均全等），证明导出过程无转义损坏、无键丢失。
4. **语法合法**：`plutil -lint` 两文件均 `OK`。

## 关键机制：键面 = 英文句本身，但**键面 ≠ 英文值**（实测 268/793）

- 代码引用的是**英文键面**，但键面与 `en` 表里存的值**并不总是同一个字符串**。
  实测 **793 键中有 268 键（34%）满足 key ≠ value**，只有 525 键 key==value。
  所以「键面即英文原文」这个说法只在 66% 的键上成立，**不能当作通则**。
- 典型三类例外：
  1. **键面是英文、值是更短的英文**：`"Auto"` → `"System"`、
     `"Usage Statistics"` → `"Usage Stats"`、`"Advanced Settings"` → `"Advanced"`、
     `"AI Generating"` → `"Generating..."`、`"Menu Bar Icon Logo"` → `"Logo"`、
     `"Show_in_Finder"` → `"Reveal in Finder"`、`"Long Screenshot"` → `"Scrolling Screenshot"`。
  2. **键面本身是英文，但值是一整句说明文案**（占绝大多数）：
     `"Fan icon speed changes with CPU usage"` → `"Rotation speed adapts to CPU usage"`；
     `"Delete Tool Confirm Title"` → `'Delete "%@"?'`。这类键面读起来像"句子"，
     其实值才是界面上真正显示的那句。
  3. **键面是中英混写或纯中文**：`'发现新版本 %@'` → `"New Version %@ Available"`、
     `'自动识别截图文字'` → `"Recognize screenshot text automatically"`、
     `'yyyy年'` → `"yyyy"`、`'settings_menu_bar_icon_fan_label'` → `"Dynamic Fan"`。
- **回退行为仍是「键面」**：`L10n.t(key)` 查不到译文时返回键面本身（而非 `en` 的值）。
  因此对于第 2、3 类键，未命中语言表时会显示"键面"（如 `Fan icon speed changes with CPU usage`）
  而不是自然英文——这是原作机制，重建侧照抄，不要"顺手优化"。
- ⚠️ **由此推出一条检索纪律**：查表必须用**键面**，不能想当然用"界面上看到的英文"。
  - 查"在访达中显示"要用键 `Show_in_Finder`（下划线）；用 `Show in Finder`（空格）查不到，
    会误判成"需要自拟键"——**这个坑我自己踩过一次**。
  - 菜单栏风扇图标的样式标签，原作其实有两个键：`settings_menu_bar_icon_fan_label` → `"Dynamic Fan"`
    与 `"Dynamic Fan Icon"` → `"Dynamic Fan"`，值相同；重建侧现用后者。
  - 同理 `"AI Generating"` 值是 `Generating...`、`"Usage Statistics"` 值是 `Usage Stats`。

## 统计窗的本地化边界（避免下一波误扩面）

specs/17 §S7c 已实证：原作统计窗是「**英文硬编码 + 部分 L10n 混合**」。
下列文案在**本 793 键中查无**，属原作硬编码，重建侧应保持英文原样、**不得自造译文**：

- 卡片标题 `"Total Interactions"` / `"Tools used today"` / `"Screenshots and color picks today"` / `"Stored Items"`
- 页脚 `"DATA IS STORED LOCALLY ON YOUR MAC"`
- 热力图节头「使用活动」、「共活跃 N 天」、tooltip「N 次」
- 柱图图例中的「剪贴板」「AI」（原作仅有 `"Clipboard Manager"`=剪切板管理、`"AI Providers"`=AI 服务商等长句，语义不等价）

统计窗**确实有** L10n 的键：`"Last 30 Days"`=过去30天、`"Screenshot"`=截图、
`"Color Picker"`=取色、`"OCR"`、`"Tool"`=工具。

## 后续扩展指引

- 重建侧接入新键时，**先在本目录查键面是否存在**；存在则抄原值，不存在则保持硬编码并加
  `TODO 待本地化` 注释——**不伪造翻译**。
- 其余 21 个语言（`ar de es fr hi id it ja ko nl pl pt-BR ru sv th tr uk vi zh-Hant-HK zh-Hant-TW`）
  的 `.lproj` 同在原作 `Resources/` 下，需要时可按同一方法批量导出。