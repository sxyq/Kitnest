# tools — 测绘工具箱

> 配合 `docs/10-规格/02-源码级测绘报告.md` 使用。全部工具已在本机验证可用。

| 工具 | 用途 | 用法 |
|---|---|---|
| `swift_fieldmd.py` | 解析 Swift `__swift5_fieldmd`/`__swift5_reflstr` 段：还原类型字段名与类型签名 | `python3 swift_fieldmd.py <arm64-slice> <out.json>` |

## 关联工具（在 frset/rea-evidence 内）

| 工具 | 位置 | 用途 |
|---|---|---|
| `da.py` | `frset/rea-evidence/tab-removal/` | 反汇编查询：`fstart`/`fwin`/`callers`/`callees`/`win` |
| `refs.py` | 同上 | adrp/add 函数指针引用解析 |
| `find_tabstrings.py` | 同上 | 立即数短字符串扫描（模式见源码） |
| `rel32scan.py` | 同上 | rel32 相对指针扫描（Swift 元数据引用） |
| `inj_kt3.m` | `frset/rea-evidence/keychain-neuter/` | 注入钩子模板：打调用者返回地址（减 ASLR slide）+ API 参数记录 |
| `pro_xref.py` | `frset/rea-evidence/ui-probe/` | 字符串交叉引用批量扫描 |
| `dump_func.py` / `find_callers_multi.py` | 同上 | 函数解剖 / 批量调用者 |

## 生成物

| 文件 | 说明 |
|---|---|
| `frset/rea-evidence/rea-early/frset-metadata-fields.json` | 96 个类型的字段元数据（含 Sentry/PostHog 协议与 Frset 自有协议） |

## 常用前置命令

```bash
# 提取 arm64 薄片（所有分析的基础）
lipo -thin arm64 /Applications/Frset.app/Contents/MacOS/Frset -output /tmp/frset_sym

# 生成反汇编（约 2 分钟，96MB）
otool -tV -arch arm64 /Applications/Frset.app/Contents/MacOS/Frset > /tmp/disasm_live.txt

# demangle
/Library/Developer/CommandLineTools/usr/bin/swift-demangle '$s5Frset16ClipboardManagerC'
```
