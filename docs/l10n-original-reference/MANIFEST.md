# MANIFEST — 原作 22 语言 L10n 键表清单

> ⚠️ 同 `README.md`：本目录是**原作资源证据件**，仅作重建参考，**不打包进 FrsetNext.app**。
> FrsetNext 实际打包的资源只有 `apps/FrsetNext/Resources/**`（当前 19 键子集）。
> 详见 `README.md` 顶部警示与机制说明。

本清单供下一波 L10n 扩展**直接取用**，无需依赖 `/Applications/Frset.app` 处于可读/挂载状态。

## 一、总览

- 语言数：**22**（与原作 `Resources/` 下 `*.lproj` 目录数一致）
- 每语言键数：**均为 793**
- **22 个语言键集与 `en` 完全一致**：差异条数全部为 `0 / 0`（双向差集皆空）
- 原作为 **Apple 二进制 plist**；本目录落盘为 **UTF-8 文本 `.strings`**（按键名字典序），可 grep / diff / `plutil -lint`
- 原作总字节：1,020,916

## 二、逐语言校验表

| 语言 | 键数 | 原作字节 | 相对 en 缺键 | 相对 en 多键 | 回读全等 | 原文件 sha256 |
|---|---|---|---|---|---|---|
| `ar` | 793 | 49918 | 0 | 0 | OK | `203eeae4805b…` |
| `de` | 793 | 51004 | 0 | 0 | OK | `c1913f4388aa…` |
| `en` | 793 | 29120 | 0 | 0 | OK | `825b49822272…` |
| `es` | 793 | 50406 | 0 | 0 | OK | `a6989b6ce218…` |
| `fr` | 793 | 54780 | 0 | 0 | OK | `ddd88dd2ff0d…` |
| `hi` | 793 | 53366 | 0 | 0 | OK | `c49d32019c5b…` |
| `id` | 793 | 40270 | 0 | 0 | OK | `b13fbbc4f09c…` |
| `it` | 793 | 47461 | 0 | 0 | OK | `d9d57a9cd59e…` |
| `ja` | 793 | 38341 | 0 | 0 | OK | `ce25b79db892…` |
| `ko` | 793 | 38832 | 0 | 0 | OK | `a976bcdd099c…` |
| `nl` | 793 | 42352 | 0 | 0 | OK | `68cd9a3ff327…` |
| `pl` | 793 | 53081 | 0 | 0 | OK | `c088cef0dc6d…` |
| `pt-BR` | 793 | 50850 | 0 | 0 | OK | `29f853aad444…` |
| `ru` | 793 | 56917 | 0 | 0 | OK | `8074e2f79a18…` |
| `sv` | 793 | 51511 | 0 | 0 | OK | `7bce3631186d…` |
| `th` | 793 | 50709 | 0 | 0 | OK | `c076f893535c…` |
| `tr` | 793 | 52513 | 0 | 0 | OK | `c1322813b6ed…` |
| `uk` | 793 | 56722 | 0 | 0 | OK | `4784bd3b35d8…` |
| `vi` | 793 | 52433 | 0 | 0 | OK | `5cafedf0197e…` |
| `zh-Hans` | 793 | 33242 | 0 | 0 | OK | `15fc37221a78…` |
| `zh-Hant-HK` | 793 | 33556 | 0 | 0 | OK | `1760069c5a47…` |
| `zh-Hant-TW` | 793 | 33532 | 0 | 0 | OK | `bbf80216f448…` |

**「回读全等」列的含义**：把本目录导出的文本件重新 `plutil` 回 JSON，与原作二进制 plist 解析结果做
**全表 `==` 比较**，结果为真。22/22 全部 OK —— 即导出过程**逐键逐值一致**，无转义损坏、无键丢失、
无顺序依赖。这比"数出 793 个"更强：键数对了但值被写坏，是数不出来的。

复核命令：
```bash
cd docs/l10n-original-reference
plutil -lint *.Localizable.strings          # 22 个全 OK
plutil -convert json -o - en.Localizable.strings | python3 -c "import json,sys;print(len(json.load(sys.stdin)))"   # → 793
```

## 三、🔴 扩展前必读：79 个「空值键」陷阱（实测）

**22 个语言里，各有 79 个键的值为空串（`""`），且 22 个语言完全相同。**

实测 `Bundle.localizedString(forKey:value:)` 在这种情况下的行为（用本目录 `zh-Hans` 件真跑）：

```
键存在·值为空 -> <空串>  (长度 0)      ← 返回空串，value 兜底【不生效】
键不存在      -> FALLBACK_WORKS        ← 正常回退到 value
```

**这意味着**：`L10n.t(key)` 对这 79 个键会返回**空字符串**（界面上表现为文案消失/空白按钮），
而**不是**回退到键面英文。二者行为不同，不能想当然。

**对重建侧的影响与处置**：
- 这 79 个键经核查全部属**付费墙/套餐/额度**类（`"Annual Plan"`、`"Buy Lifetime Access"`、
  `"Choose a Pro Plan"`、`"Free plans include up to %d tool uses per day…"`、`"Upgrade to Pro"` 等），
  加上 `"Midnight Appearance"`、`"Tool Usage"` 等。
- 重建侧本就不移植付费墙，且**已打包的 19 键中空值键为 0 个**，故**当前无影响**。
- 下一波若把这些键接入，**要么跳过空值键**（保持硬编码），**要么在 `t()` 里显式处理**
  `result.isEmpty → 返回 key`。**不要**默认"回退键面"会兜住空值——实测不会。

## 四、扩展操作指引

1. 先在本目录查**键面**是否存在（注意：键面 ≠ 界面英文，可能形态不同，见 `README.md` 检索纪律）。
2. 命中则抄该语言的值；**不臆造翻译**——查不到就保持硬编码并加 `TODO 待本地化`。
3. 复制到 `apps/FrsetNext/Resources/<lang>.lproj/Localizable.strings` 时注意：
   - **增删语言必须双向校验键集**（`set(en) == set(新语言)`），只查"缺键"会漏掉"多键"。
   - 避开第 3 节的 79 个空值键。
4. 打包由 `build.sh` 的「== 资源 ==」段自动完成（`Resources/` → `Contents/Resources/`，严格在 codesign 前）。

## 五、相关文件

- `README.md` —— 来源/抽取方法、键面机制（含 268/793 键面≠值的更正）、检索纪律、统计窗本地化边界
- `MANIFEST.md` —— 本文件：逐语言校验表 + 空值键陷阱