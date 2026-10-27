import Foundation

/// 部件设置全量自测（仅 `FRSET_WIDGET_SELFTEST=1` 时运行）。
///
/// 目的：不依赖鼠标，把「设置 → 性能监测 → 部件设置」能改的每一项配置
/// 都写入 → 重建菜单栏 → 读回校验，并在结束时把 widgets.plist 恢复到测试前。
///
/// 覆盖：
///   · 7 个模块的启用/停用
///   · 每个模块的每一种形态（含只读的 label/state/run_cat）
///   · 每个形态的每一个选项（开关/菜单/颜色，含 custom:#RRGGBB）
///   · 更新间隔全部档位、传感器全部 key 的首尾
///   · 布局：合并开关、间距 none/1–8、分隔线
///   · 维护：初始化默认、重新导入 Stats
///   · 覆盖断言：UI 选项表必须与引擎设置窗的键集合完全一致
enum WidgetSettingsSelfTest {

    private static let storePath = NSHomeDirectory()
        + "/Library/Application Support/FrsetStats/widgets.plist"

    private static var total = 0
    private static var failures: [String] = []
    private static var perModule: [String: Int] = [:]

    /// 引擎设置窗（frset_barsettings.m FSFormSettingsView）的权威键集合。
    /// UI 表少一个键 = 功能缺失；多一个键 = 写了引擎不认识的配置。
    private static let expectedKeys: [String: [String]] = [
        "mini":          ["label", "color", "alignment"],
        "line_chart":    ["label", "value", "box", "frame", "color", "valueColor", "historyCount", "scale"],
        "bar_chart":     ["label", "color", "box", "frame"],
        "pie_chart":     ["label", "monochrome"],
        "tachometer":    ["label", "monochrome"],
        "network_chart": ["label", "box", "frame", "reversedOrder",
                          "downloadColor", "uploadColor", "historyCount", "scale"],
        "speed":         ["displayValue", "mode", "icon", "iconColor", "iconAlignment",
                          "value", "valueColor", "valueAlignment", "units",
                          "monochrome", "downloadColor", "uploadColor"],
        "memory":        ["color", "symbols", "orderReversed"],
        "battery":       ["display", "color"],
        "icon":          ["icon"],
        "label":         [],
        "state":         [],
        "run_cat":       [],
    ]

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["FRSET_WIDGET_SELFTEST"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            run()
        }
    }

    // MARK: - 主流程

    private static func run() {
        NSLog("[WidgetSelfTest] ===== 开始 =====")
        guard let original = NSDictionary(contentsOfFile: storePath) as? [String: Any] else {
            NSLog("[WidgetSelfTest] 无法读取 widgets.plist，终止")
            return
        }
        // 额外留一份文件级备份，便于人工兜底
        _ = NSDictionary(dictionary: original).write(toFile: "/tmp/frset_widgets_selftest_backup.plist",
                                                     atomically: true)

        testLayout()
        testModules()
        testMaintenance()

        restore(original)
        report()
    }

    // MARK: - 布局

    private static func testLayout() {
        let oldMerged = FSBarMergedEnabled()
        let oldSeparator = FSBarMergedSeparator()
        let oldSpacing = (FSBarGlobalRaw("CombinedModules_spacing") as? String) ?? "none"

        FSBarGlobalSet("CombinedModules", true)
        FSBarReloadFromStore()
        check(FSBarMergedEnabled(), "布局/合并模块：开启")

        // v134：间距滑条 0–24pt、0.5 步进——抽验边界、默认与含小数档位
        for (raw, expected) in [("0", CGFloat(0)), ("3", CGFloat(3)),
                                ("3.5", CGFloat(3.5)), ("24", CGFloat(24))] {
            FSBarGlobalSet("CombinedModules_spacing", raw)
            FSBarGlobalSet("Widgets_spacing", raw)
            FSBarReloadFromStore()
            checkEqual(FSBarMergedSpacing(), expected, "布局/间距 \(raw)pt")
        }

        FSBarGlobalSet("CombinedModules_separator", true)
        FSBarReloadFromStore()
        check(FSBarMergedSeparator(), "布局/分隔线：开")
        FSBarGlobalSet("CombinedModules_separator", false)
        FSBarReloadFromStore()
        check(!FSBarMergedSeparator(), "布局/分隔线：关")

        FSBarGlobalSet("CombinedModules", false)
        FSBarReloadFromStore()
        check(!FSBarMergedEnabled(), "布局/合并模块：关闭")

        // 还原
        FSBarGlobalSet("CombinedModules", oldMerged)
        FSBarGlobalSet("CombinedModules_separator", oldSeparator)
        FSBarGlobalSet("CombinedModules_spacing", oldSpacing)
        FSBarReloadFromStore()
    }

    // MARK: - 模块 / 形态 / 选项

    private static func testModules() {
        let modules = (FSBarAllModules() as? [String]) ?? []
        check(modules.count == 7, "模块列表应为 7 个（实际 \(modules.count)）")

        for module in modules {
            let allForms = (FSBarFormsForModule(module) as? [String]) ?? []
            let originalForms = (FSBarEnabledForms(module) as? [String]) ?? []
            let originalInterval = Int(FSBarCfgInt(module, nil, "updateInterval", 1))

            // 模块开关：关 → 开
            FSBarSetEnabledForms(module, [])
            FSBarReloadFromStore()
            check(((FSBarEnabledForms(module) as? [String]) ?? []).isEmpty,
                  "\(module)/模块开关：关闭")
            if let first = allForms.first {
                FSBarSetEnabledForms(module, [first])
                FSBarReloadFromStore()
                checkEqual((FSBarEnabledForms(module) as? [String]) ?? [], [first],
                           "\(module)/模块开关：开启默认形态")
            }

            // 每个形态：启用后测选项
            for form in allForms {
                FSBarSetEnabledForms(module, [form])
                FSBarReloadFromStore()
                checkEqual((FSBarEnabledForms(module) as? [String]) ?? [], [form],
                           "\(module)/\(form)：单独启用")

                let groups = MonitorWidgetsPane.optionGroups(module: module, form: form)
                let specs = groups.flatMap { $0.options }
                let keys = specs.map { key(of: $0) }

                if let expected = expectedKeys[form] {
                    checkEqual(Set(keys), Set(expected),
                               "\(module)/\(form)：选项键集合与引擎一致（UI=\(keys.sorted())）")
                }
                checkEqual(keys.count, Set(keys).count,
                           "\(module)/\(form)：选项无重复键")

                for spec in specs {
                    testOption(module: module, form: form, spec: spec)
                }
                perModule[module, default: 0] += specs.count
            }

            // 更新间隔全部档位（v134：滑条 1–60 秒——抽验边界与中点）
            for value in [1, 30, 60] {
                FSBarCfgSet(module, nil, "updateInterval", NSNumber(value: value))
                FSBarReloadFromStore()
                checkEqual(Int(FSBarCfgInt(module, nil, "updateInterval", 1)), value,
                           "\(module)/间隔：\(value) 秒")
            }
            FSBarCfgSet(module, nil, "updateInterval", NSNumber(value: originalInterval))

            // 传感器选择（首尾两个 key）
            if module == "Sensors" {
                let keys = (FSBarSensorKeysList() as? [String]) ?? []
                check(!keys.isEmpty, "Sensors/传感器列表非空（实际 \(keys.count) 个）")
                let originalSensor = FSBarCfgStr(module, nil, "sensor", "PPBR") ?? "PPBR"
                for key in [keys.first, keys.last].compactMap({ $0 }) {
                    FSBarCfgSet(module, nil, "sensor", key)
                    FSBarReloadFromStore()
                    checkEqual(FSBarCfgStr(module, nil, "sensor", "PPBR") ?? "", key,
                               "Sensors/传感器选择：\(key)")
                }
                FSBarCfgSet(module, nil, "sensor", originalSensor)
            }

            // 还原模块
            FSBarSetEnabledForms(module, originalForms)
            FSBarReloadFromStore()
            checkEqual((FSBarEnabledForms(module) as? [String]) ?? [], originalForms,
                       "\(module)：形态列表已还原")
        }
    }

    private static func testOption(module: String, form: String, spec: OptionSpec) {
        switch spec.kind {
        case .toggle(let key, let def):
            let old = FSBarCfgBool(module, form, key, def)
            FSBarCfgSet(module, form, key, NSNumber(value: !old))
            FSBarReloadFromStore()
            checkEqual(FSBarCfgBool(module, form, key, def), !old,
                       "\(module)/\(form)/\(key)：开关切换")
            FSBarCfgSet(module, form, key, NSNumber(value: old))

        case .menu(let key, let items, let def):
            let old = FSBarCfgStr(module, form, key, def) ?? def
            let target = items.map { $0.0 }.first { $0 != old } ?? old
            FSBarCfgSet(module, form, key, target)
            FSBarReloadFromStore()
            checkEqual(FSBarCfgStr(module, form, key, def) ?? "", target,
                       "\(module)/\(form)/\(key)：菜单 \(old) → \(target)")
            FSBarCfgSet(module, form, key, old)

        case .color(let key, let def):
            let old = FSBarCfgStr(module, form, key, def) ?? def
            FSBarCfgSet(module, form, key, "custom:#123456")
            FSBarReloadFromStore()
            checkEqual(FSBarCfgStr(module, form, key, def) ?? "", "custom:#123456",
                       "\(module)/\(form)/\(key)：自定义色")
            FSBarCfgSet(module, form, key, "red")
            FSBarReloadFromStore()
            checkEqual(FSBarCfgStr(module, form, key, def) ?? "", "red",
                       "\(module)/\(form)/\(key)：预设色")
            FSBarCfgSet(module, form, key, old)

        case .slider(let key, let def, let min, let max, let step, _):
            // v134：滑条选项自检——默认值合法（在区间内）、步进对齐写回
            let old = FSBarCfgStr(module, form, key, def) ?? def
            let defV = Double(old) ?? min
            check(defV >= min && defV <= max, "\(module)/\(form)/\(key)：默认值 \(old) 在 [\(min), \(max)] 内")
            let mid = ((min + max) / 2 / step).rounded() * step
            FSBarCfgSet(module, form, key, String(format: "%.0f", mid))
            FSBarReloadFromStore()
            checkEqual(FSBarCfgStr(module, form, key, def) ?? "", String(format: "%.0f", mid),
                       "\(module)/\(form)/\(key)：滑条写回 \(mid)")
            FSBarCfgSet(module, form, key, old)
        }
    }

    private static func key(of spec: OptionSpec) -> String {
        switch spec.kind {
        case .toggle(let key, _): return key
        case .menu(let key, _, _): return key
        case .color(let key, _): return key
        case .slider(let key, _, _, _, _, _): return key
        }
    }

    // MARK: - 维护

    private static func testMaintenance() {
        FSBarResetToDefaults()
        check(!((FSBarEnabledForms("CPU") as? [String]) ?? []).isEmpty,
              "维护/初始化：CPU 有默认形态")
        // 布局默认是「拆分」——v44 起用「键不存在」表示 false，不写 CombinedModules
        check(!FSBarMergedEnabled(), "维护/初始化：布局回到默认拆分")

        FSBarResetFromStats()
        check(!((FSBarEnabledForms("CPU") as? [String]) ?? []).isEmpty,
              "维护/重新导入 Stats：CPU 有形态")
    }

    // MARK: - 校验 / 还原 / 报告

    // v126（性能审计 F1199）：断言文案改 @autoclosure 惰性求值——原来即使断言通过，
    // 也会把 `keys.sorted()`、`diffKeys(整个字典对比)` 等结果拼进字符串再丢掉，
    // testModules 的几百次断言白白付了字符串与排序成本。调用点写法不变。
    private static func check(_ condition: Bool, _ label: @autoclosure () -> String) {
        total += 1
        if !condition { failures.append(label()) }
    }

    private static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: @autoclosure () -> String) {
        total += 1
        if actual != expected {
            failures.append("\(label())（实际 \(actual)，期望 \(expected)）")
        }
    }

    private static func restore(_ original: [String: Any]) {
        let current = NSDictionary(contentsOfFile: storePath) as? [String: Any] ?? [:]
        for key in current.keys where original[key] == nil && !key.hasPrefix("NSPos_") {
            FSBarGlobalSet(key, nil)
        }
        for (key, value) in original where !key.hasPrefix("NSPos_") {
            FSBarGlobalSet(key, value)
        }
        FSBarReloadFromStore()

        // NSPos_* 是状态项位置缓存：reload 期间校准会重写它，必须在最后一次
        // rebuild 之后再写回（不再 reload，避免又触发一次校准）。
        for (key, value) in original where key.hasPrefix("NSPos_") {
            FSBarGlobalSet(key, value)
        }

        let after = NSDictionary(contentsOfFile: storePath) as? [String: Any] ?? [:]
        let ok = NSDictionary(dictionary: after).isEqual(to: original)
        check(ok, "配置已恢复到测试前（差异键：\(diffKeys(after, original))）")
    }

    private static func diffKeys(_ a: [String: Any], _ b: [String: Any]) -> String {
        let keys = Set(a.keys).union(b.keys)
        let diff = keys.filter { key in
            let av = a[key] as? NSObject
            let bv = b[key] as? NSObject
            if av == nil && bv == nil { return false }
            return !(av?.isEqual(bv) ?? false)
        }
        return diff.sorted().prefix(6).joined(separator: ",")
    }

    private static func report() {
        let summary = "[WidgetSelfTest] 完成：\(total) 项检查，失败 \(failures.count) 项；"
            + "模块选项覆盖 \(perModule.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
        NSLog("%@", summary)
        if !failures.isEmpty {
            for f in failures {
                NSLog("[WidgetSelfTest] FAIL %@", f)
            }
        }
        try? (summary + "\n" + failures.map { "FAIL " + $0 }.joined(separator: "\n"))
            .write(toFile: "/tmp/frset_widget_selftest.txt", atomically: true, encoding: .utf8)
    }
}
