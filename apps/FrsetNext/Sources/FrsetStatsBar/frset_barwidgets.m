// frset_barwidgets.m — 状态栏部件引擎（Stats SWidget 忠实复刻 + 设置驱动 + 状态项管理）
// ============================================================================
// 依据 stats-source/Kit/Widgets/ 与 Kit/plugins/Charts.swift 逐项复刻：
//   mini / line_chart / bar_chart / pie_chart / network_chart / speed /
//   memory / tachometer / battery / label / state / icon
// 设置键名与 Stats 完全一致（M_widget 列表 + M_<form>_<option> 选项），
// 存储于 ~/Library/Application Support/FrsetStats/widgets.plist，
// 首启自动从 eu.exelban.Stats 导入（配置互通）。
// ============================================================================
#import "frset_barwidgets.h"
#import "frset_stats_data.h"
#import "frset_runcat_frames.h"          // v32 移植（注入版）：奔跑小猫帧资源（RunCat Neo，Apache 2.0）
#import <CoreGraphics/CoreGraphics.h>   // v14：点击链路诊断（CGEvent / CGWarp）

FSSnap g_snap;

// ============ 基础常量 / 模块与形态表 ============

// 间距只放在相邻内容之间，不再叠加每个部件的左右内边距。

// v126（性能审计 F1631/F1649）：模块列表改为 static 常量——原先每次调用都
// 分配一个新 NSArray（0.5s tick 内 FSBarReconcile + FSBarMergedLayout 合计调 3+ 次）。
NSArray<NSString *> *FSBarAllModules(void) {
    static NSArray<NSString *> *mods;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mods = @[@"CPU", @"RAM", @"GPU", @"Disk", @"Network", @"Sensors", @"Battery", @"Power", @"CPUPower", @"GPUPower"]; });
    return mods;
}

// 面板模块索引（FSBarOpenMonitor 用）
static int FSBarModuleIndex(NSString *m) {
    if ([m isEqualToString:@"CPU"]) return 0;
    if ([m isEqualToString:@"RAM"]) return 1;
    if ([m isEqualToString:@"GPU"]) return 2;
    if ([m isEqualToString:@"Disk"]) return 3;
    if ([m isEqualToString:@"Network"]) return 4;
    if ([m isEqualToString:@"Sensors"]) return 5;
    if ([m isEqualToString:@"Battery"]) return 6;
    if ([@[@"Power", @"CPUPower", @"GPUPower"] containsObject:m]) return 7;
    return 0;
}

// 各模块支持的部件形态（顺序即设置列表顺序；第 1 个接管原生图标位）
NSArray<NSString *> *FSBarFormsForModule(NSString *m) {
    // v126（性能审计 F1631/F1649）：形态表改为 dispatch_once 缓存——原先每次调用
    // 都分配一个新 NSArray 字面量（0.5s tick 内 FSBarEnabledForms 被调 14+ 次）。
    // v89（2026-10-20 用户：「展示方式不够多，原版每个数值都有很多方式」）：
    // 通用形态（迷你/折线/柱状/饼/仪表/环形/波形/点阵/进度条/标签/图标）全模块放开，
    // 模块专属形态（speed/memory/network_chart/battery/state）保持原样。
    static NSDictionary<NSString *, NSArray<NSString *> *> *map;
    static NSArray<NSString *> *common;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        common = @[@"mini", @"line_chart", @"bar_chart", @"pie_chart",
                   @"tachometer", @"ring", @"wave", @"dots", @"bar",
                   @"label", @"icon"];
        map = @{
            @"CPU":     @[@"line_chart", @"mini", @"bar_chart", @"pie_chart", @"tachometer", @"ring", @"wave", @"dots", @"bar", @"label", @"icon"],
            @"RAM":     @[@"bar_chart", @"mini", @"line_chart", @"pie_chart", @"memory", @"tachometer", @"ring", @"wave", @"dots", @"bar", @"label", @"icon"],
            @"GPU":     @[@"mini", @"line_chart", @"tachometer", @"ring", @"wave", @"dots", @"bar", @"pie_chart", @"label", @"icon"],
            @"Disk":    @[@"mini", @"bar_chart", @"network_chart", @"speed", @"pie_chart", @"line_chart", @"memory", @"ring", @"wave", @"dots", @"bar", @"label", @"icon"],
            @"Network": @[@"speed", @"network_chart", @"wave", @"dots", @"state", @"label", @"icon"],
            @"Sensors": @[@"mini", @"ring", @"bar", @"wave", @"dots", @"label", @"icon"],
            @"Battery": @[@"mini", @"battery", @"bar_chart", @"ring", @"wave", @"dots", @"bar", @"state", @"label", @"icon"],
            @"Power": @[@"mini", @"line_chart", @"icon"],
            @"CPUPower": @[@"mini", @"line_chart", @"icon"],
            @"GPUPower": @[@"mini", @"line_chart", @"icon"],
        };
    });
    return map[m] ?: common;
}

// 形态中文名（设置界面用）
NSString *FSBarFormName(NSString *form) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"mini": @"迷你（数值）", @"line_chart": @"折线图", @"bar_chart": @"柱状图",
                @"pie_chart": @"饼图", @"network_chart": @"网络图", @"speed": @"速度",
                @"memory": @"内存", @"tachometer": @"仪表盘", @"battery": @"电池",
                @"label": @"标签", @"state": @"状态点", @"icon": @"图标",
                @"ring": @"环形图", @"wave": @"波形图", @"dots": @"点阵", @"bar": @"进度条"};
    });
    return map[form] ?: form;
}

NSString *FSBarModuleName(NSString *m) {
    if ([m isEqualToString:@"CPU"]) return @"CPU";
    if ([m isEqualToString:@"RAM"]) return @"内存";
    if ([m isEqualToString:@"GPU"]) return @"GPU";
    if ([m isEqualToString:@"Disk"]) return @"磁盘";
    if ([m isEqualToString:@"Network"]) return @"网络";
    if ([m isEqualToString:@"Sensors"]) return @"传感器";
    if ([m isEqualToString:@"Battery"]) return @"电池";
    if ([m isEqualToString:@"Power"]) return @"功耗";
    if ([m isEqualToString:@"CPUPower"]) return @"CPU 功耗";
    if ([m isEqualToString:@"GPUPower"]) return @"GPU 功耗";
    return m;
}

// 原生状态项映射（Frset 自带三个监控图标）
static NSString *FSBarNativeModule(NSString *autosaveName) {
    if ([autosaveName isEqualToString:@"frset.metrics.network"]) return @"Network";
    if ([autosaveName isEqualToString:@"frset.metrics.memory"]) return @"RAM";
    if ([autosaveName isEqualToString:@"frset.metrics.ssd"]) return @"Disk";
    return nil;
}

// ============ 设置存储（键名对齐 Stats） ============

static NSMutableDictionary *g_cfg = nil;
// v126（性能审计 F1631/F1649）：配置代数计数器——FSBarEnabledForms 的缓存失效依据。
// 配置变更（CfgSet / ReloadFromStore / ResetToDefaults）时递增，缓存命中时跳过
// 字符串分割 + 过滤（原先 0.5s tick 内被调 14+ 次，每次 ~3 次 NSArray 分配）。
static int g_cfgGen = 0;
static NSString *FSBarStorePath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/FrsetStats"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"widgets.plist"];
}

// 从 eu.exelban.Stats 域读取键（导入互通）
static id FSBarStatsValue(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("eu.exelban.Stats"));
    return v ? (__bridge_transfer id)v : nil;
}

// 各形态可导入的选项键（bool 自动判定）
static NSArray<NSArray<NSString *> *> *FSBarImportableKeys(void) {
    return @[
        @[@"mini", @"label"], @[@"mini", @"color"], @[@"mini", @"alignment"],
        @[@"line_chart", @"label"], @[@"line_chart", @"box"], @[@"line_chart", @"frame"],
        @[@"line_chart", @"value"], @[@"line_chart", @"valueColor"], @[@"line_chart", @"color"],
        @[@"line_chart", @"historyCount"], @[@"line_chart", @"scale"],
        @[@"bar_chart", @"label"], @[@"bar_chart", @"box"], @[@"bar_chart", @"frame"], @[@"bar_chart", @"color"],
        @[@"pie_chart", @"label"], @[@"pie_chart", @"monochrome"],
        @[@"network_chart", @"label"], @[@"network_chart", @"box"], @[@"network_chart", @"frame"],
        @[@"network_chart", @"reversedOrder"], @[@"network_chart", @"downloadColor"], @[@"network_chart", @"uploadColor"],
        @[@"speed", @"icon"], @[@"speed", @"value"], @[@"speed", @"units"], @[@"speed", @"monochrome"],
        @[@"speed", @"valueColor"], @[@"speed", @"valueAlignment"], @[@"speed", @"mode"],
        @[@"speed", @"downloadColor"], @[@"speed", @"uploadColor"], @[@"speed", @"displayValue"],
        @[@"memory", @"symbols"], @[@"memory", @"orderReversed"], @[@"memory", @"color"],
        @[@"tachometer", @"label"], @[@"tachometer", @"monochrome"],
        @[@"battery", @"display"], @[@"battery", @"color"],
        @[@"state", @"color"], @[@"icon", @"icon"],
    ];
}

static void FSBarSeedDefaults(NSMutableDictionary *cfg) {
    cfg[@"CombinedModules"] = @NO;
    cfg[@"CombinedModules_separator"] = @YES;
    cfg[@"Widgets_spacing"] = @"2";
    cfg[@"CombinedModules_spacing"] = @"2";
    // 与用户当前 Stats 使用习惯一致的出厂默认（无 Stats 可导入时）
    cfg[@"CPU_widget"] = @"line_chart";
    cfg[@"CPU_line_chart_label"] = @1; cfg[@"CPU_line_chart_box"] = @1; cfg[@"CPU_line_chart_value"] = @1;
    cfg[@"RAM_widget"] = @"bar_chart";
    cfg[@"GPU_widget"] = @"";
    cfg[@"Disk_widget"] = @"mini";
    cfg[@"Disk_mini_title"] = @"SSD"; cfg[@"Disk_mini_label"] = @1;
    cfg[@"Network_widget"] = @"speed";
    cfg[@"Network_speed_icon"] = @"dots"; cfg[@"Network_speed_valueAlignment"] = @"left";
    cfg[@"Sensors_widget"] = @"mini";
    cfg[@"Sensors_mini_label"] = @1; cfg[@"Sensors_mini_color"] = @"monochrome"; cfg[@"Sensors_sensor"] = @"PPBR";
    cfg[@"Battery_widget"] = @"mini";
    for (NSString *module in @[@"Power", @"CPUPower", @"GPUPower"]) {
        cfg[[module stringByAppendingString:@"_widget"]] = @"";
        cfg[[module stringByAppendingString:@"_mini_label"]] = @YES;
        cfg[[module stringByAppendingString:@"_mini_color"]] = @"monochrome";
        cfg[[module stringByAppendingString:@"_line_chart_value"]] = @YES;
    }
}

// 从 Stats 导入（模块列表 + 支持的选项；不支持的形态丢弃）
static void FSBarImportFromStats(NSMutableDictionary *cfg) {
    NSArray *modules = FSBarAllModules();
    for (NSString *m in modules) {
        id list = FSBarStatsValue([m stringByAppendingString:@"_widget"]);
        if ([list isKindOfClass:[NSString class]]) {
            NSMutableArray *keep = [NSMutableArray array];
            NSArray *supported = FSBarFormsForModule(m);
            for (NSString *f in [list componentsSeparatedByString:@","]) {
                if ([supported containsObject:f] && ![keep containsObject:f]) [keep addObject:f];
            }
            cfg[[m stringByAppendingString:@"_widget"]] = [keep componentsJoinedByString:@","];
        }
        id interval = FSBarStatsValue([m stringByAppendingString:@"_updateInterval"]);
        if (interval) cfg[[m stringByAppendingString:@"_updateInterval"]] = interval;
        for (NSArray *tuple in FSBarImportableKeys()) {
            NSString *form = tuple[0], *key = tuple[1];
            if (![FSBarFormsForModule(m) containsObject:form]) continue;
            id v = FSBarStatsValue([NSString stringWithFormat:@"%@_%@_%@", m, form, key]);
            if (v) cfg[[NSString stringWithFormat:@"%@_%@_%@", m, form, key]] = v;
        }
    }
    // 合并显示（CombinedModules 系列；用户 Stats 已启用时 Frset 跟随）
    id cm = FSBarStatsValue(@"CombinedModules");
    if (cm) cfg[@"CombinedModules"] = cm;
    id cmSpacing = FSBarStatsValue(@"CombinedModules_spacing");
    if ([cmSpacing isKindOfClass:[NSString class]]) cfg[@"Widgets_spacing"] = cmSpacing;
    id cmSep = FSBarStatsValue(@"CombinedModules_separator");
    if (cmSep) cfg[@"CombinedModules_separator"] = cmSep;
    // 特殊键
    id sensor = FSBarStatsValue(@"Sensors_sensor");
    if ([sensor isKindOfClass:[NSString class]] && [sensor length]) cfg[@"Sensors_sensor"] = sensor;
    cfg[@"Disk_mini_title"] = @"SSD";
    // 原生项模块（Network/RAM/Disk）：Stats 里未启用时回落默认形态
    // —— Frset 自带这三个图标，不能因 Stats 的关闭状态而消失
    NSDictionary *nativeDefaults = @{@"Network": @"speed", @"RAM": @"bar_chart", @"Disk": @"mini"};
    for (NSString *m in nativeDefaults) {
        NSString *list = [cfg[[m stringByAppendingString:@"_widget"]] isKindOfClass:[NSString class]]
                             ? cfg[[m stringByAppendingString:@"_widget"]] : @"";
        if (!(list.length)) {
            cfg[[m stringByAppendingString:@"_widget"]] = nativeDefaults[m];
            if ([m isEqualToString:@"Disk"]) { cfg[@"Disk_mini_label"] = @1; }
            if ([m isEqualToString:@"Network"]) { cfg[@"Network_speed_icon"] = @"dots"; cfg[@"Network_speed_valueAlignment"] = @"left"; }
        }
    }
}

static void FSBarLoadStore(void) {
    if (g_cfg) return;
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:FSBarStorePath()];
    if (loaded) {
        g_cfg = [loaded mutableCopy];
    } else {
        g_cfg = [NSMutableDictionary dictionary];
        FSBarImportFromStats(g_cfg);     // 配置互通：首启从 Stats 导入
        if (!g_cfg[@"CPU_widget"] && !g_cfg[@"RAM_widget"] && !g_cfg[@"Network_widget"]) {
            FSBarSeedDefaults(g_cfg);
        }
        [g_cfg writeToFile:FSBarStorePath() atomically:YES];
        NSLog(@"[FrsetStats] 部件设置已初始化（来源：%@）",
              g_cfg[@"CPU_widget"] ? @"eu.exelban.Stats 导入" : @"出厂默认");
    }
}

void FSBarSaveStore(void) {
    if (!g_cfg) return;
    [g_cfg writeToFile:FSBarStorePath() atomically:YES];
}

NSString *FSBarCfgKey(NSString *module, NSString *form, NSString *key) {
    if (!form || form.length == 0) return [NSString stringWithFormat:@"%@_%@", module, key];
    return [NSString stringWithFormat:@"%@_%@_%@", module, form, key];
}

id FSBarCfgRaw(NSString *module, NSString *form, NSString *key) {
    FSBarLoadStore();
    return g_cfg[FSBarCfgKey(module, form, key)];
}

void FSBarCfgSet(NSString *module, NSString *form, NSString *key, id value) {
    FSBarLoadStore();
    NSString *k = FSBarCfgKey(module, form, key);
    if (value == nil) [g_cfg removeObjectForKey:k];
    else g_cfg[k] = value;
    g_cfgGen++;   // v126：配置变更 → FSBarEnabledForms 缓存失效
    FSBarSaveStore();
}

static BOOL FSBarAsBool(id v, BOOL def) {
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v boolValue];
    return def;
}

BOOL FSBarCfgBool(NSString *module, NSString *form, NSString *key, BOOL def) {
    return FSBarAsBool(FSBarCfgRaw(module, form, key), def);
}

NSString *FSBarCfgStr(NSString *module, NSString *form, NSString *key, NSString *def) {
    id v = FSBarCfgRaw(module, form, key);
    return [v isKindOfClass:[NSString class]] ? v : def;
}

int FSBarCfgInt(NSString *module, NSString *form, NSString *key, int def) {
    id v = FSBarCfgRaw(module, form, key);
    return [v respondsToSelector:@selector(intValue)] ? [v intValue] : def;
}

// 该模块启用的形态列表（已过滤到支持的形态）
NSArray<NSString *> *FSBarEnabledForms(NSString *module) {
    FSBarLoadStore();
    // v126（性能审计 F1631/F1649）：按模块缓存结果 + 配置代数失效。原先 0.5s tick 内
    // FSBarReconcile + FSBarMergedLayout 合计调 14+ 次，每次做 dict 查找 + 逗号分割 +
    // N×containsObject 过滤（约 3 次 NSArray 分配）。缓存命中时直接返回。
    static NSMutableDictionary<NSString *, NSArray<NSString *> *> *cache;
    static int cacheGen = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (cacheGen != g_cfgGen) {
        [cache removeAllObjects];
        cacheGen = g_cfgGen;
    }
    NSArray<NSString *> *cached = cache[module];
    if (cached) return cached;

    NSArray<NSString *> *result = FSBarConfiguredForms(module, g_cfg);
    cache[module] = result;
    return result;
}

NSArray<NSString *> *FSBarPowerMetrics(NSDictionary *cfg) {
    NSArray *metrics = @[@"Power", @"CPUPower", @"GPUPower"];
    NSString *selected = cfg[@"Power_metrics"];
    NSArray *selectedMetrics = [selected componentsSeparatedByString:@","];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *metric in metrics) {
        BOOL enabled = selected != nil ? [selectedMetrics containsObject:metric]
                       : [cfg[[metric stringByAppendingString:@"_widget"]] length] > 0;
        if (enabled) [out addObject:metric];
    }
    return out;
}

NSArray<NSString *> *FSBarConfiguredForms(NSString *module, NSDictionary *cfg) {
    NSMutableArray *lists = [NSMutableArray arrayWithObject:cfg[[module stringByAppendingString:@"_widget"]] ?: @""];
    if ([module isEqualToString:@"Power"]) {
        if (!FSBarPowerMetrics(cfg).count) return @[];
        if (!cfg[@"Power_metrics"]) {
            for (NSString *metric in @[@"CPUPower", @"GPUPower"])
                [lists addObject:cfg[[metric stringByAppendingString:@"_widget"]] ?: @""];
        }
    }
    NSArray *supported = FSBarFormsForModule(module);
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *list in lists)
        for (NSString *f in [list componentsSeparatedByString:@","])
            if (f.length && [supported containsObject:f] && ![out containsObject:f]) [out addObject:f];
    return out;
}

void FSBarSetEnabledForms(NSString *module, NSArray<NSString *> *forms) {
    if ([module isEqualToString:@"Power"] && !FSBarGlobalRaw(@"Power_metrics")) {
        NSArray *metrics = FSBarPowerMetrics(g_cfg);
        FSBarCfgSet(module, nil, @"metrics", [(metrics.count ? metrics : @[@"Power", @"CPUPower", @"GPUPower"]) componentsJoinedByString:@","]);
    }
    FSBarCfgSet(module, nil, @"widget", [forms componentsJoinedByString:@","]);
}

// 模块刷新间隔（秒，1..10；对齐 Stats updateInterval）
static NSTimeInterval FSBarModuleInterval(NSString *module) {
    int v = FSBarCfgInt(module, nil, @"updateInterval", 1);
    return MIN(60, MAX(1, v));   // v15：对齐 Stats ReaderUpdateIntervals（1..60s）
}

// ---- 全局键（非模块级：CombinedModules 系列；键名对齐 Stats） ----
id FSBarGlobalRaw(NSString *key) {
    FSBarLoadStore();
    return g_cfg[key];
}

void FSBarGlobalSet(NSString *key, id value) {
    FSBarLoadStore();
    if (value == nil) [g_cfg removeObjectForKey:key];
    else g_cfg[key] = value;
    FSBarSaveStore();
}

NSDictionary *FSBarConfigurationSnapshot(void) {
    if (g_cfg) return [g_cfg copy];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/FrsetStats/widgets.plist"];
    return [NSDictionary dictionaryWithContentsOfFile:path] ?: FSBarDefaultConfiguration();
}

NSDictionary *FSBarDefaultConfiguration(void) {
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    FSBarSeedDefaults(cfg);
    return cfg;
}

NSDictionary *FSBarImportedConfiguration(void) {
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    FSBarImportFromStats(cfg);
    return cfg;
}

NSString *FSBarSaveConfiguration(NSDictionary *values, NSArray<NSString *> *removedKeys) {
    NSMutableDictionary *next = [FSBarConfigurationSnapshot() mutableCopy];
    [next addEntriesFromDictionary:values];
    [next removeObjectsForKeys:removedKeys];
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:next
                      format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!data || ![data writeToFile:FSBarStorePath() options:NSDataWritingAtomic error:&error])
        return error.localizedDescription;
    g_cfg = next;
    g_cfgGen++;
    return nil;
}

static id FSBarViewCfgRaw(NSDictionary *cfg, NSString *module, NSString *form, NSString *key) {
    return cfg ? cfg[FSBarCfgKey(module, form, key)] : FSBarCfgRaw(module, form, key);
}
static BOOL FSBarViewCfgBool(NSDictionary *cfg, NSString *module, NSString *form, NSString *key, BOOL def) {
    return FSBarAsBool(FSBarViewCfgRaw(cfg, module, form, key), def);
}
static NSString *FSBarViewCfgStr(NSDictionary *cfg, NSString *module, NSString *form, NSString *key, NSString *def) {
    id value = FSBarViewCfgRaw(cfg, module, form, key);
    return [value isKindOfClass:NSString.class] ? value : def;
}
static int FSBarViewCfgInt(NSDictionary *cfg, NSString *module, NSString *form, NSString *key, int def) {
    id value = FSBarViewCfgRaw(cfg, module, form, key);
    return value ? [value intValue] : def;
}

static BOOL FSBarGlobalBool(NSString *key, BOOL def) { return FSBarAsBool(FSBarGlobalRaw(key), def); }
static NSString *FSBarGlobalStr(NSString *key, NSString *def) {
    id v = FSBarGlobalRaw(key);
    return [v isKindOfClass:[NSString class]] ? v : def;
}

// 合并显示设置（对齐 Stats CombinedView：status / spacing / separator）
// v44 移植（注入版）：默认拆分（用户要求"状态栏组件拆分"；合并需在设置里显式开启）
BOOL FSBarMergedEnabled(void)   { return FSBarGlobalBool(@"CombinedModules", NO); }
BOOL FSBarMergedSeparator(void) { return FSBarGlobalBool(@"CombinedModules_separator", YES); }
// v89（2026-10-20 用户：「各个部件的间距用统一的一个设置」）：
//   统一间距键 Widgets_spacing（0-12，pt）——同时作用于
//   · 合并条内「部件与部件」的间距（原 CombinedModules_spacing）
//   · 各部件内部「图标/标签/数值」的间隙（原硬编码 2/6/12）
//   旧键 CombinedModules_spacing 仅作迁移兼容（新键未设时读旧值）。
CGFloat FSBarConfigurationSpacing(NSDictionary *cfg) {
    id value = cfg[@"Widgets_spacing"] ?: cfg[@"CombinedModules_spacing"];
    if (!value) return 2;
    if ([value isEqual:@"none"]) return 0;
    if ([value isEqual:@"Widgets_uniform"]) return 2;
    return MAX(0, MIN(24, [value doubleValue]));
}
CGFloat FSBarWidgetSpacing(void) {
    FSBarLoadStore();
    return FSBarConfigurationSpacing(g_cfg);
}
CGFloat FSBarMergedSpacing(void) {
    FSBarLoadStore();
    return FSBarConfigurationSpacing(g_cfg);
}
NSArray<NSString *> *FSBarOrderedModules(NSDictionary *cfg) {
    NSArray *order = cfg[@"Widgets_order"] ?: FSBarAllModules();
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *candidate in [order arrayByAddingObjectsFromArray:FSBarAllModules()]) {
        NSString *module = [candidate hasSuffix:@"Power"] ? @"Power" : candidate;
        if ([FSBarAllModules() containsObject:module] && ![result containsObject:module]) [result addObject:module];
    }
    return result;
}

// ============ 颜色 / 数值辅助 ============

void FSBarLog(NSString *fmt, ...);   // 引擎日志（跨文件可用：drawRect 探针 / OPENCHK 等；定义于文件后部）

// ============ v19：菜单栏背景明暗 —— 像素实测（唯一可靠信号） ============
// 为什么必须实测：v18 的 FRSET_APPEARCHK 探针证明——自建状态项的
//   button/view.effectiveAppearance 恒为 VibrantDark，而原版 metrics 项恒为 VibrantLight，
//   二者与菜单栏实际背景无关（同一条菜单栏不可能左右两半不同色）。用 appearance 判定，
//   在**浅色菜单栏**上会照旧画白图标 → 用户反馈"图标没有做黑/白反相自适应"。
// 做法：截取菜单栏横条（取菜单栏下部 1/3 带，避开图标/菜单文字）→ 亮度中位数：
//   中位数 < 128 → 背景偏深 → 白图标；否则 → 黑图标。后台线程采样，2s 节流。

static void FSBarRefreshAllWidgets(void);   // 前向声明（定义于文件后部）

// v77（2026-10-19 全盘排查）：**不再用截屏判断菜单栏明暗**。
// 原实现每 2s 调一次 dlsym 取到的 CGDisplayCreateImageForRect —— 该 API 属于
// 屏幕录制 TCC 管辖，会让系统反复弹「需要屏幕录制权限」，即使已授权也会因
// 自签名 code identity 变化而反复请求。现完全改为「视图绘制上下文外观」
// （与 Stats 原生 isDarkMode 同源，vibrant 系可识别浅色/深色菜单栏），
// 绘制时按视图自身外观取色，不再维护全局像素采样。
static BOOL FSBarAppearanceDark(NSView *v) {
    NSAppearance *ap = (v && v.effectiveAppearance) ? v.effectiveAppearance : NSApp.effectiveAppearance;
    if (!ap) ap = NSApp.effectiveAppearance;
    NSAppearanceName n = [ap bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
        NSAppearanceNameVibrantLight, NSAppearanceNameVibrantDark,
        NSAppearanceNameAccessibilityHighContrastAqua,
        NSAppearanceNameAccessibilityHighContrastDarkAqua,
        NSAppearanceNameAccessibilityHighContrastVibrantLight,
        NSAppearanceNameAccessibilityHighContrastVibrantDark]];
    return [n containsString:@"Dark"];
}

// v18：反相信号源改为"视图绘制上下文的外观"——对齐 Stats 原版实现：
//   stats-source/Kit/extensions.swift:365  NSView.isDarkMode → effectiveAppearance
//   stats-source/Kit/helpers.swift:1676      isDarkMode → NSAppearance.currentDrawing()
// 两者都识别 vibrant 系：状态栏按钮上下文 = VibrantLight（浅色菜单栏）/ VibrantDark
// （深色菜单栏，含 Tahoe 按背景自动反相的情形）→ 部件文字/图标随之黑/白反相，
// 与系统 template 图标的观感一致。
// 历史教训修正：v10~v17 用 NSApp.effectiveAppearance 并注释"按钮上下文恒为
// VibrantDark"——该结论经 v18 探针（FRSET_APPEARCHK）复核为误判（把深色系统下的
// 一次观测误推广）；App 级外观感知不到菜单栏/壁纸触发的反相，正是用户反馈
// "图标颜色没有做系统自适应"的根因。
static BOOL FSBarDark(NSView *v) {
    // v77：全部走视图绘制上下文外观，无任何截屏/全局缓存
    return FSBarAppearanceDark(v);
}

// 前景文本色：硬编码白/黑双值（对齐 Stats 的 isDarkMode 着色方式）。
// 不用动态 FSBarTextColor(dark) —— 状态栏按钮 vibrant 上下文会把动态色解析成白色。
static NSColor *FSBarTextColor(BOOL dark) { return dark ? [NSColor whiteColor] : [NSColor blackColor]; }

// v15：全量 Stats SColor 表（键名与 eu.exelban.Stats 逐字一致）+ custom:#RRGGBBAA 支持
static NSColor *FSBarColorFromKey(NSString *key, BOOL dark, double value) {
    if (!key || key.length == 0) return [NSColor controlAccentColor];
    if ([key hasPrefix:@"custom:"]) {
        NSString *hex = [[key substringFromIndex:7] stringByReplacingOccurrencesOfString:@"#" withString:@""];
        unsigned long long v = 0; unsigned int r = 0, g = 0, b = 0, a = 255;
        if ([[NSScanner scannerWithString:hex] scanHexLongLong:&v] && hex.length >= 6) {
            r = (unsigned)((v >> 16) & 0xff); g = (unsigned)((v >> 8) & 0xff); b = (unsigned)(v & 0xff);
            if (hex.length >= 8) a = (unsigned)((v >> 24) & 0xff);
            if (hex.length == 6) { r = (unsigned)((v >> 16) & 0xff); g = (unsigned)((v >> 8) & 0xff); b = (unsigned)(v & 0xff); }
            return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
        }
        return [NSColor controlAccentColor];
    }
    // 动态色
    if ([key isEqualToString:@"monochrome"]) return dark ? [NSColor whiteColor] : [NSColor blackColor];
    if ([key isEqualToString:@"system"]) return [NSColor controlAccentColor];
    if ([key isEqualToString:@"utilization"]) {
        if (value >= 0.8) return [NSColor systemRedColor];
        if (value >= 0.6) return [NSColor systemOrangeColor];
        return [NSColor systemGreenColor];
    }
    if ([key isEqualToString:@"pressure"]) {
        if (value >= 0.8) return [NSColor systemRedColor];
        if (value >= 0.6) return [NSColor systemOrangeColor];
        return [NSColor systemGreenColor];
    }
    if ([key isEqualToString:@"cluster"]) return [NSColor controlAccentColor];
    // 静态色（对齐 Stats：Red=NSColor.red、Second red=NSColor.systemRed …）
    static NSDictionary<NSString *, NSColor *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"clear": [NSColor clearColor], @"white": [NSColor whiteColor], @"black": [NSColor blackColor],
            @"gray": [NSColor grayColor], @"secondGray": [NSColor systemGrayColor],
            @"darkGray": [NSColor darkGrayColor], @"lightGray": [NSColor lightGrayColor],
            @"red": [NSColor redColor], @"secondRed": [NSColor systemRedColor],
            @"green": [NSColor greenColor], @"secondGreen": [NSColor systemGreenColor],
            @"blue": [NSColor blueColor], @"secondBlue": [NSColor systemBlueColor],
            @"yellow": [NSColor yellowColor], @"secondYellow": [NSColor systemYellowColor],
            @"orange": [NSColor orangeColor], @"secondOrange": [NSColor systemOrangeColor],
            @"purple": [NSColor purpleColor], @"secondPurple": [NSColor systemPurpleColor],
            @"brown": [NSColor brownColor], @"secondBrown": [NSColor systemBrownColor],
            @"cyan": [NSColor cyanColor], @"magenta": [NSColor magentaColor],
            @"pink": [NSColor systemPinkColor], @"teal": [NSColor systemTealColor],
            @"indigo": [NSColor systemIndigoColor],
        };
    });
    NSColor *c = map[key];
    return c ?: [NSColor controlAccentColor];
}


// 设置界面的颜色候选（key 对齐 Stats SColor 常用项）
NSArray<NSString *> *FSBarColorKeys(void) {
    return @[@"systemAccent", @"monochrome", @"utilization", @"red", @"green", @"blue",
             @"yellow", @"orange", @"purple", @"pink", @"gray"];
}


// Stats grayscaled() 近似
static NSColor *FSBarGray(NSColor *c) {
    NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: c;
    double g = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent;
    return [NSColor colorWithSRGBRed:g green:g blue:g alpha:1];
}

// Stats Units.getReadableSpeed 复刻（十进制 1000）
static NSString *FSSpeedStr(uint64_t bytes) {
    double v = (double)bytes;
    if (v < 1000)       return @"0 KB/s";
    if (v < 1000000)    return [NSString stringWithFormat:@"%.0f KB/s", v / 1e3];
    if (v < 100000000)  return [NSString stringWithFormat:@"%.1f MB/s", v / 1e6];
    if (v < 1000000000) return [NSString stringWithFormat:@"%.0f MB/s", v / 1e6];
    if (v < 1e12)       return [NSString stringWithFormat:@"%.1f GB/s", v / 1e9];
    return [NSString stringWithFormat:@"%.1f TB/s", v / 1e12];
}

// 短速率为速度部件 oneRow 模式（省略单位）
static NSString *FSSpeedStrShort(uint64_t bytes) {
    NSString *s = FSSpeedStr(bytes);
    NSRange r = [s rangeOfString:@" "];
    return r.location == NSNotFound ? s : [s substringToIndex:r.location];
}

// 可读容量（Stats getReadableMemory 近似："8.2 GB"）
static NSString *FSSizeStr(double bytes) {
    const char *u[] = {"B", "KB", "MB", "GB", "TB"};
    int i = 0; double v = bytes;
    while (v >= 1024 && i < 4) { v /= 1024; i++; }
    return [NSString stringWithFormat:(i <= 1 ? @"%.0f %s" : @"%.1f %s"), v, u[i]];
}

// 剩余时间（Stats printSecondsToHoursMinutesSeconds 近似）
static NSString *FSRemainStr(double minutes) {
    if (minutes < 0) return @"--:--";
    int m = (int)(minutes + 0.5);
    return [NSString stringWithFormat:@"%d:%02d", m / 60, m % 60];
}

// 模块主值（返回显示串 + 归一化比例 value）
static double FSBarModuleValue(const FSSnap *s, NSString *module, NSString **str, NSString **suffix) {
    if (suffix) *suffix = @"";
    if ([@[@"Power", @"CPUPower", @"GPUPower"] containsObject:module]) {
        double watts = [module isEqualToString:@"Power"] ? s->power.system_w :
            [module isEqualToString:@"CPUPower"] ? s->power.cpu_w : s->power.gpu_w;
        if (str) *str = isfinite(watts) && watts >= 0 ? [NSString stringWithFormat:@"%.1f W", watts] : @"—";
        if (suffix) *suffix = @"W";
        return isfinite(watts) && watts >= 0 ? watts : NAN;
    }
    if ([module isEqualToString:@"CPU"]) {
        if (str) *str = [NSString stringWithFormat:@"%.0f%%", s->cpuUsage * 100];
        if (suffix) *suffix = @"%";
        return s->cpuUsage;
    }
    if ([module isEqualToString:@"RAM"]) {
        if (str) *str = [NSString stringWithFormat:@"%.0f%%", s->ramRatio * 100];
        if (suffix) *suffix = @"%";
        return s->ramRatio;
    }
    if ([module isEqualToString:@"GPU"]) {
        if (str) *str = [NSString stringWithFormat:@"%.0f°", s->gpuTemp];
        if (suffix) *suffix = @"°";
        return MIN(1.0, s->gpuTemp / 110.0);
    }
    if ([module isEqualToString:@"Disk"]) {
        if (str) *str = [NSString stringWithFormat:@"%.0f%%", s->diskUsedRatio * 100];
        if (suffix) *suffix = @"%";
        return s->diskUsedRatio;
    }
    if ([module isEqualToString:@"Network"]) {
        if (str) *str = FSSpeedStrShort((uint64_t)s->netDownBps);
        return MIN(1.0, s->netDownBps / 1e8);
    }
    if ([module isEqualToString:@"Sensors"]) {
        if (str) *str = [NSString stringWithFormat:@"%.0f°", s->sensorValue];
        if (suffix) *suffix = @"°";
        return MIN(1.0, s->sensorValue / 110.0);
    }
    if ([module isEqualToString:@"Battery"]) {
        if (str) *str = [NSString stringWithFormat:@"%.0f%%", s->batteryPercent];
        if (suffix) *suffix = @"%";
        return s->batteryPercent / 100.0;
    }
    if (str) *str = @"--";
    return 0;
}

// 模块主值显示（mini/line 值标签用）：温度已带 °，百分比已带 %
static NSString *FSBarModuleString(const FSSnap *s, NSString *module) {
    NSString *str = nil;
    FSBarModuleValue(s, module, &str, NULL);
    return str;
}

// 温度类模块（动态缩放折线）
static BOOL FSBarModuleIsRatio(NSString *module) {
    return [module isEqualToString:@"CPU"] || [module isEqualToString:@"RAM"] ||
           [module isEqualToString:@"Disk"] || [module isEqualToString:@"Battery"];
}

// ============ 文本绘制辅助（flipped 视图） ============

// v28：菜单栏小字号对像素网格极敏感——绘制原点一律 floor 到整数 pt（2x 屏 = 2px 网格），
//   消除半像素落点导致的"发虚"。所有部件文本都经这两个函数，一处修复全栏受益。
static void FSBarTextCenter(NSString *s, NSDictionary *attrs, CGFloat x, CGFloat centerY) {
    NSSize sz = [s sizeWithAttributes:attrs];
    [s drawAtPoint:NSMakePoint(floor(x), floor(centerY - sz.height / 2)) withAttributes:attrs];
}

static void FSBarTextRect(NSString *s, NSDictionary *attrs, NSRect r, NSTextAlignment align) {
    r.origin.x = floor(r.origin.x);
    r.origin.y = floor(r.origin.y);
    // v129（内存）：段落样式按对齐缓存（只有3 种对齐）——原实现每次文本绘制都
    // 新建 NSMutableParagraphStyle + mutableCopy attrs（部件每 0.5s tick 重绘 ×
    // 每部件多次文本调用），是 tick 路径稳定的双份小对象churn。
    static NSMutableParagraphStyle *leftPS, *centerPS, *rightPS;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        leftPS = [[NSMutableParagraphStyle alloc] init];   leftPS.alignment = NSTextAlignmentLeft;
        centerPS = [[NSMutableParagraphStyle alloc] init]; centerPS.alignment = NSTextAlignmentCenter;
        rightPS = [[NSMutableParagraphStyle alloc] init];  rightPS.alignment = NSTextAlignmentRight;
    });
    NSMutableParagraphStyle *ps = (align == NSTextAlignmentCenter) ? centerPS
                                : (align == NSTextAlignmentRight) ? rightPS : leftPS;
    NSMutableDictionary *a = [attrs mutableCopy];
    a[NSParagraphStyleAttributeName] = ps;
    [s drawInRect:r withAttributes:a];
}

// 用正式字体测量实际文字；等宽数字保留同位数读数的稳定性。
static CGFloat FSBarNumberWidth(NSString *text, CGFloat size, NSFontWeight weight) {
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
    return ceil([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
}

// ============ 部件视图（12 形态） ============

// ======== v32/v34/v35 移植（注入版）：奔跑小猫 RunCat ========
//   帧资源：RunCat Neo（https://github.com/runcat-dev/RunCatNeo，Apache License 2.0）
//     5 帧循环 · 56×36 · 黑白双版（浅色菜单栏→黑猫 / 深色→白猫）
//   动画：主图标使用 10Hz 定时器推进帧号；小猫关闭时定时器停止；
//     v81：倍速 7 档 0.5~1.5×（用户：最高只能 1.5 倍），基础 8fps → 有效 4~12fps
//   主图标按钮按帧切换模板图；设置预览由 FSRunCatIconView 绘制。
//   开关：widgets.plist 键 Bar_MainIconCat（缺省=关）；设置即时生效。
static int g_runCatFrame = 0;
static double g_runCatCpuEMA = 0;
typedef NS_ENUM(NSInteger, FSRunCatImageVariant) {
    FSRunCatImageBlack,
    FSRunCatImageWhite,
    FSRunCatImageTemplate,
};
static NSMutableDictionary<NSNumber *, NSImage *> *g_runCatImgs = nil;
static NSTimer *g_runCatTimer = nil;
// v32/v34 前向声明（实现见 FSBarWidgetView @end 之后的 run_cat static 区）
static NSImage *FSRunCatImage(int idx, FSRunCatImageVariant variant);
static void FSRunCatStartTimer(void);
static void FSRunCatStopTimer(void);
// 主图标使用原生按钮图像；预览视图沿用相同帧资源。
// v43（2026-10-18 用户指示）：**默认关闭**——状态栏主图标回到之前版本
// （动态风扇 / Logo / 日期，由通用页「菜单栏图标」选择）。奔跑小猫只是注入版
// 的额外玩法，不再默认覆盖官方图标；想要的用户可在设置里勾选「小猫」。
static BOOL g_mainIconCatEnabled = NO;
static BOOL g_mainIconCatInited = NO;
static int g_mainIconCatLastFrame = -1;

// 设置预览中的小猫动画视图。
@interface FSRunCatIconView : NSView
@property (nonatomic, strong) NSNumber *fixedFrame;
@property (nonatomic, strong) NSTimer *previewTimer;
- (void)stopPreview;
- (void)updatePreviewAnimation:(NSNotification *)notification;
@end

@interface FSBarWidgetView : NSView
@property (nonatomic, copy) NSString *module;
@property (nonatomic, copy) NSString *form;
@property (nonatomic, copy) NSDictionary *configuration; // nil = 正式保存配置；预览注入草稿
@property (nonatomic) FSSnap snap;          // 最近一次刷新的数据
@property (nonatomic) int histN;
@property (nonatomic) CFAbsoluteTime lastUpdate;
- (instancetype)initWithModule:(NSString *)m form:(NSString *)f;
- (void)refreshWithSnap:(const FSSnap *)s;
- (CGFloat)preferredWidth;
- (CGFloat)speedValueWidth:(uint64_t)bytes;
- (double)primaryValue;                     // 当前主值（归一化 0..1 或原值）
@end

// v32：g_views 定义提前（run_cat 定时器需引用；原定义在状态项管理器区已移除）
static NSMutableDictionary<NSString *, FSBarWidgetView *> *g_views = nil;   // "module/form" → 部件视图

@implementation FSBarWidgetView {
    double _hist[130];      // line_chart 历史
    double _histIn[130];    // network_chart 下行历史
    double _histOut[130];   // network_chart 上行历史
}

- (instancetype)initWithModule:(NSString *)m form:(NSString *)f {
    self = [super initWithFrame:NSMakeRect(0, 0, 40, 22)];
    if (self) {
        _module = [m copy];
        _form = [f copy];
        _lastUpdate = 0;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)p { return nil; }   // 点击穿透到状态栏按钮

// ---- 数据刷新（按模块间隔由管理器调用） ----
- (void)refreshWithSnap:(const FSSnap *)s {
    self.snap = *s;
    _lastUpdate = CFAbsoluteTimeGetCurrent();
    if ([_form isEqualToString:@"line_chart"]) {
        double v = [self primaryValue];
        if (isfinite(v)) {
            if (_histN < 129) { _hist[_histN] = v; _histN++; }
            else { memmove(_hist, _hist + 1, 129 * sizeof(double)); _hist[129] = v; }
        }
    } else if ([_form isEqualToString:@"network_chart"]) {
        double in = [self netIn], out = [self netOut];
        if (_histN < 129) {
            _histIn[_histN] = in; _histOut[_histN] = out; _histN++;
        } else {
            memmove(_histIn, _histIn + 1, 129 * sizeof(double)); _histIn[129] = in;
            memmove(_histOut, _histOut + 1, 129 * sizeof(double)); _histOut[129] = out;
        }
    }
    [self setNeedsDisplay:YES];
}

- (double)netIn {   // 下行 / 读取
    if ([_module isEqualToString:@"Network"]) return self.snap.netDownBps;
    if ([_module isEqualToString:@"Disk"]) return self.snap.diskReadBps;
    return 0;
}

- (double)netOut {  // 上行 / 写入
    if ([_module isEqualToString:@"Network"]) return self.snap.netUpBps;
    if ([_module isEqualToString:@"Disk"]) return self.snap.diskWriteBps;
    return 0;
}

- (double)primaryValue {
    NSString *metric = [_module isEqualToString:@"Power"] ? FSBarPowerMetrics(_configuration ?: g_cfg).firstObject : _module;
    return FSBarModuleValue(&_snap, metric, NULL, NULL);
}

// 一组功耗共用双排几何；整机独占上排，CPU/GPU 同处下排。
- (NSArray<NSArray<NSString *> *> *)powerRows {
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *chips = [NSMutableArray array];
    for (NSString *metric in FSBarPowerMetrics(_configuration ?: g_cfg)) {
        if ([metric isEqualToString:@"Power"]) [rows addObject:@[metric]];
        else [chips addObject:metric];
    }
    if (rows.count && chips.count) [rows addObject:chips];
    else for (NSString *metric in chips) [rows addObject:@[metric]];
    return rows;
}

- (NSString *)powerText:(NSString *)metric value:(NSString *)value {
    BOOL labels = FSBarViewCfgBool(_configuration, @"Power", _form, @"label", YES);
    NSString *name = [metric isEqualToString:@"Power"] ? @"整机" : ([metric isEqualToString:@"CPUPower"] ? @"CPU" : @"GPU");
    return labels ? [NSString stringWithFormat:@"%@ %@", name, value] : value;
}

- (CGFloat)powerVisualWidth {
    if ([_form isEqualToString:@"icon"]) return 17;
    if (![_form isEqualToString:@"line_chart"]) return 0;
    int hc = FSBarViewCfgInt(_configuration, @"Power", _form, @"historyCount", 60);
    return hc <= 30 ? 24 : (hc <= 60 ? 32 : (hc <= 90 ? 42 : 52));
}

// ---- 宽度（逐值对齐 Stats v3.0.21：Constants.Widget.margin.x = 0，无额外内边距） ----
// 图表使用6pt竖排字母列，宽度和绘制坐标共用。
- (CGFloat)labelWidth {
    return 6;
}

- (CGFloat)speedValueWidth:(uint64_t)bytes {
    BOOL units = FSBarViewCfgBool(_configuration, _module, _form, @"units", YES);
    BOOL oneRow = [FSBarViewCfgStr(_configuration, _module, _form, @"mode", @"twoRows") isEqualToString:@"oneRow"];
    return FSBarNumberWidth(units ? FSSpeedStr(bytes) : FSSpeedStrShort(bytes), oneRow ? 11 : 9,
                            oneRow ? NSFontWeightRegular : NSFontWeightLight);
}

- (CGFloat)preferredWidth {
    if ([_module isEqualToString:@"Power"]) {
        CGFloat width = 0;
        CGFloat gap = FSBarConfigurationSpacing(_configuration ?: g_cfg);
        for (NSArray *row in [self powerRows]) {
            CGFloat rowWidth = 0;
            for (NSString *metric in row) rowWidth += FSBarNumberWidth([self powerText:metric value:FSBarModuleString(&_snap, metric)], 9, NSFontWeightRegular);
            width = MAX(width, rowWidth + (row.count - 1) * gap);
        }
        CGFloat visual = [self powerVisualWidth];
        return width + (visual ? visual + gap : 0);
    }
    if ([_form isEqualToString:@"mini"]) {
        BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label",
                                  [_module isEqualToString:@"Sensors"] || [_module isEqualToString:@"Disk"] || [_module hasSuffix:@"Power"]);
        NSDictionary *lattrs = @{NSFontAttributeName: [NSFont systemFontOfSize:7 weight:NSFontWeightLight]};
        CGFloat labelW = label ? [[self moduleLabel] sizeWithAttributes:lattrs].width : 0;
        return MAX(ceil(labelW), FSBarNumberWidth(FSBarModuleString(&_snap, _module), label ? 12 : 14, NSFontWeightRegular));
    }
    if ([_form isEqualToString:@"speed"]) {
        BOOL value = FSBarViewCfgBool(_configuration, _module, _form, @"value", YES);
        NSString *icon = FSBarViewCfgStr(_configuration, _module, _form, @"icon", @"dots");
        NSString *mode = FSBarViewCfgStr(_configuration, _module, _form, @"mode", @"twoRows");
        NSString *display = FSBarViewCfgStr(_configuration, _module, _form, @"displayValue", @"oi");
        BOOL iconOn = (icon && ![icon isEqualToString:@"none"]);
        CGFloat gap = iconOn && value ? FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
        CGFloat inWidth = [self speedValueWidth:(uint64_t)[self netIn]];
        CGFloat outWidth = [self speedValueWidth:(uint64_t)[self netOut]];
        CGFloat textWidth = display.length == 1 ? ([display isEqualToString:@"i"] ? inWidth : outWidth) :
            ([mode isEqualToString:@"oneRow"] ? inWidth + outWidth + FSBarConfigurationSpacing(_configuration ?: g_cfg) : MAX(inWidth, outWidth));
        return (iconOn ? 8 : 0) + gap + (value ? textWidth : 0);
    }
    CGFloat gap = FSBarConfigurationSpacing(_configuration ?: g_cfg);
    if ([_form isEqualToString:@"line_chart"] || [_form isEqualToString:@"wave"]) {
        // Stats LineChart.width：30→24 / 60→32 / 90→42 / 120→52；label 再 +（6 + spacing）
        int hc = FSBarViewCfgInt(_configuration, _module, _form, @"historyCount", 60);
        CGFloat w = (hc <= 30) ? 24 : (hc <= 60 ? 32 : (hc <= 90 ? 42 : 52));
        return w + (FSBarViewCfgBool(_configuration, _module, _form, @"label", NO) ? ([self labelWidth] + gap) : 0);
    }
    if ([_form isEqualToString:@"bar_chart"]) {
        // Stats BarChart.draw：单条（RAM 单柱）→ 10 + offset*2 ≈ 11
        return 11 + (FSBarViewCfgBool(_configuration, _module, _form, @"label", NO) ? ([self labelWidth] + gap) : 0);
    }
    if ([_form isEqualToString:@"network_chart"]) {
        // Stats NetworkChart init：30 + label?(6 + spacing)
        return 30 + (FSBarViewCfgBool(_configuration, _module, _form, @"label", NO) ? ([self labelWidth] + gap) : 0);
    }
    if ([_form isEqualToString:@"ring"]) {
        CGFloat size = MIN(self.bounds.size.height, 20);
        return size + (FSBarViewCfgBool(_configuration, _module, _form, @"label", NO) ? ([self labelWidth] + gap) : 0);
    }
    if ([_form isEqualToString:@"dots"]) {
        return 20 + (FSBarViewCfgBool(_configuration, _module, _form, @"label", NO) ? ([self labelWidth] + gap) : 0);
    }
    if ([_form isEqualToString:@"bar"]) {
        return 28 + (FSBarViewCfgBool(_configuration, _module, _form, @"label", NO) ? ([self labelWidth] + gap) : 0);
    }
    if ([_form isEqualToString:@"memory"]) {
        double total = [_module isEqualToString:@"Disk"] ? _snap.diskTotalBytes : _snap.ramTotalBytes;
        double used = [_module isEqualToString:@"Disk"] ? MAX(0, total - _snap.diskFreeBytes) : _snap.ramUsedBytes;
        return MAX(FSBarNumberWidth(FSSizeStr(used), 9, NSFontWeightLight),
                   FSBarNumberWidth(FSSizeStr(MAX(0, total - used)), 9, NSFontWeightLight))
            + (FSBarViewCfgBool(_configuration, _module, _form, @"symbols", YES) ? 8 + gap : 0);
    }
    if ([_form isEqualToString:@"pie_chart"] || [_form isEqualToString:@"tachometer"]) {
        // Stats：size(=height) + label?(6 + spacing)；本实现 size = MIN(h, 20)
        CGFloat size = MIN(self.bounds.size.height, 20);
        return size + (FSBarViewCfgBool(_configuration, _module, _form, @"label", NO) ? ([self labelWidth] + gap) : 0);
    }
    if ([_form isEqualToString:@"battery"]) {
        NSString *disp = FSBarViewCfgStr(_configuration, _module, _form, @"display", @"percentage");
        if ([disp isEqualToString:@"none"]) return 25;
        CGFloat percentage = FSBarNumberWidth(_snap.batteryPresent ? [NSString stringWithFormat:@"%.0f%%", _snap.batteryPercent] : @"—", 9, NSFontWeightLight);
        CGFloat time = FSBarNumberWidth(_snap.batteryPresent ? FSRemainStr(_snap.batteryRemainMin) : @"—", 9, NSFontWeightLight);
        return 25 + gap + ([disp isEqualToString:@"time"] ? time : ([disp containsString:@"And"] ? MAX(time, percentage) : percentage));
    }
    if ([_form isEqualToString:@"label"]) return 6;    // Stats Label：letterWidth 6
    if ([_form isEqualToString:@"state"]) return 8;    // Stats Dot：8x8
    if ([_form isEqualToString:@"icon"]) return 20;    // SF Symbol 14pt ≈ 18-20
    return 32;
}

// ---- 标签字母列（Stats NSLabelCharts：模块名前 3 字母、反转后自上而下绘制） ----
- (void)drawLabelColumn:(NSString *)module at:(CGFloat)x dark:(BOOL)dark height:(CGFloat)H {
    NSArray *chars = [self labelChars];
    CGFloat letterH = H / 3.0;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:7 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: FSBarTextColor(dark)};
    CGFloat y = 0;
    for (NSString *c in chars) {
        FSBarTextRect(c, attrs, NSMakeRect(x, y, 6, letterH), NSTextAlignmentCenter);
        y += letterH;
    }
}

- (NSArray<NSString *> *)labelChars {
    // 与 Stats 一致：title.prefix(3).uppercased().reversed()，自上而下绘制
    static NSDictionary *titles = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        titles = @{@"CPU": @"CPU", @"RAM": @"RAM", @"GPU": @"GPU", @"Disk": @"Disk",
                   @"Network": @"Network", @"Sensors": @"Sensors", @"Battery": @"Battery"};
    });
    NSString *t = titles[_module] ?: _module;
    if (t.length > 3) t = [t substringToIndex:3];
    t = [t uppercaseString];
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = (NSInteger)t.length - 1; i >= 0; i--) {
        [out addObject:[t substringWithRange:NSMakeRange(i, 1)]];
    }
    return out;
}

// 模块标签标题（mini / 传感器用）
- (NSString *)moduleLabel {
    if ([_module isEqualToString:@"Sensors"]) {
        return FSBarViewCfgStr(_configuration, _module, @"mini", @"sensor", FSBarViewCfgStr(_configuration, _module, nil, @"sensor", @"PPBR"));
    }
    if ([_module isEqualToString:@"Disk"]) {
        return FSBarViewCfgStr(_configuration, _module, @"mini", @"title", @"SSD");
    }
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = @{@"CPU": @"CPU", @"RAM": @"RAM", @"GPU": @"GPU",
                                    @"Network": @"NET", @"Battery": @"BAT",
                                    @"Power": @"整机", @"CPUPower": @"CPU", @"GPUPower": @"GPU"}; });
    return map[_module] ?: _module;
}

// ---- 主绘制 ----
// v18：外观（明暗反相）变化时确保重绘——菜单栏按壁纸/系统切换反相时，
//   AppKit 会改变按钮的 effectiveAppearance（VibrantLight↔VibrantDark）。
- (void)viewDidChangeEffectiveAppearance {
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    // v18 探针（FRSET_APPEARCHK=1）：打印绘制上下文的外观信号，验证反相源是否可靠
    static int s_appearLogged = 0;
    if (!_configuration && getenv("FRSET_APPEARCHK") && s_appearLogged < 8) {
        s_appearLogged++;
        FSBarLog(@"[appear:draw %d] %@/%@ view.effective=%@ currentDrawing=%@ dark=%d",
                 s_appearLogged, _module, _form,
                 self.effectiveAppearance.name,
                 NSAppearance.currentDrawingAppearance.name, (int)FSBarDark(self));
    }
    BOOL dark = FSBarDark(self);
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;

    NSRect cr = NSMakeRect(0, 0, W, H);
    [NSGraphicsContext saveGraphicsState];

    if ([_module isEqualToString:@"Power"]) { [self drawPower:cr dark:dark]; }
    else if ([_form isEqualToString:@"mini"])       { [self drawMini:cr dark:dark]; }
    else if ([_form isEqualToString:@"speed"]) { [self drawSpeed:cr dark:dark]; }
    else if ([_form isEqualToString:@"bar_chart"]) { [self drawBarChart:cr dark:dark]; }
    else if ([_form isEqualToString:@"pie_chart"]) { [self drawPie:cr dark:dark]; }
    else if ([_form isEqualToString:@"tachometer"]) { [self drawTachometer:cr dark:dark]; }
    else if ([_form isEqualToString:@"ring"]) { [self drawRing:cr dark:dark]; }
    else if ([_form isEqualToString:@"wave"]) { [self drawWave:cr dark:dark]; }
    else if ([_form isEqualToString:@"dots"]) { [self drawDots:cr dark:dark]; }
    else if ([_form isEqualToString:@"bar"]) { [self drawProgressBar:cr dark:dark]; }
    else if ([_form isEqualToString:@"line_chart"]) { [self drawLineChart:cr dark:dark]; }
    else if ([_form isEqualToString:@"network_chart"]) { [self drawNetworkChart:cr dark:dark]; }
    else if ([_form isEqualToString:@"memory"]) { [self drawMemory:cr dark:dark]; }
    else if ([_form isEqualToString:@"battery"]) { [self drawBattery:cr dark:dark]; }
    else if ([_form isEqualToString:@"label"]) { [self drawLabelColumn:_module at:0 dark:dark height:H]; }
    else if ([_form isEqualToString:@"state"]) { [self drawState:cr dark:dark]; }
    else if ([_form isEqualToString:@"icon"]) { [self drawIcon:cr dark:dark]; }
    else { [self drawMini:cr dark:dark]; }   // v71：未知/废弃 form（含存量 run_cat）fallback mini

    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawPower:(NSRect)r dark:(BOOL)dark {
    CGFloat visual = [self powerVisualWidth];
    if ([_form isEqualToString:@"line_chart"]) [self drawLineChart:NSMakeRect(0, 0, visual, r.size.height) dark:dark];
    else if ([_form isEqualToString:@"icon"]) [self drawIcon:NSMakeRect(0, 0, visual, r.size.height) dark:dark];
    NSColor *color = FSBarColorFromKey(FSBarViewCfgStr(_configuration, @"Power", _form, @"color", @"monochrome"), dark, [self primaryValue]);
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular], NSForegroundColorAttributeName: color};
    NSArray *rows = [self powerRows];
    CGFloat gap = FSBarConfigurationSpacing(_configuration ?: g_cfg);
    CGFloat startX = visual ? visual + gap : 0;
    CGFloat rowHeight = r.size.height / rows.count;
    CGFloat y = 0;
    for (NSArray *row in rows) {
        CGFloat x = startX;
        for (NSString *metric in row) {
            NSString *text = [self powerText:metric value:FSBarModuleString(&_snap, metric)];
            CGFloat width = FSBarNumberWidth(text, 9, NSFontWeightRegular);
            FSBarTextRect(text, attrs,
                          NSMakeRect(x, y, width, rowHeight), NSTextAlignmentLeft);
            x += width + gap;
        }
        y += rowHeight;
    }
}

// ======== 形态 1：mini（Stats Mini.swift） ========
- (void)drawMini:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label",
                              [_module isEqualToString:@"Sensors"] || [_module isEqualToString:@"Disk"] || [_module hasSuffix:@"Power"]);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"monochrome");
    // 沿用既有对齐选项，文字宽度与布局采用同一读数。
    NSString *align = FSBarViewCfgStr(_configuration, _module, _form, @"alignment", @"left");
    NSString *val = FSBarModuleString(&_snap, _module);
    double v = [self primaryValue];
    NSColor *c = FSBarColorFromKey(colorKey, dark, v);
    NSTextAlignment ta = [align isEqualToString:@"right"] ? NSTextAlignmentRight :
                         ([align isEqualToString:@"center"] ? NSTextAlignmentCenter : NSTextAlignmentLeft);
    if (label) {
        NSDictionary *lattrs = @{NSFontAttributeName: [NSFont systemFontOfSize:7 weight:NSFontWeightLight],
                                 NSForegroundColorAttributeName: FSBarTextColor(dark)};
        FSBarTextRect([self moduleLabel], lattrs, NSMakeRect(0, 1, r.size.width, 8), ta);
        NSDictionary *vattrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular],
                                 NSForegroundColorAttributeName: c};
        FSBarTextRect(val, vattrs, NSMakeRect(0, 8, r.size.width, 14), ta);   // v28：8.5→8（半像素发虚）
    } else {
        NSDictionary *vattrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightRegular],
                                 NSForegroundColorAttributeName: c};
        FSBarTextRect(val, vattrs, NSMakeRect(0, 3, r.size.width, 17), ta);
    }
}

// ======== 形态 2：speed（Stats Speed.swift；输入=下载/读取，输出=上传/写入） ========
- (void)drawSpeed:(NSRect)r dark:(BOOL)dark {
    BOOL valueOn = FSBarViewCfgBool(_configuration, _module, _form, @"value", YES);
    BOOL units = FSBarViewCfgBool(_configuration, _module, _form, @"units", YES);
    BOOL mono = FSBarViewCfgBool(_configuration, _module, _form, @"monochrome", NO);
    NSString *icon = FSBarViewCfgStr(_configuration, _module, _form, @"icon", @"dots");
    NSString *align = FSBarViewCfgStr(_configuration, _module, _form, @"valueAlignment", @"left");
    NSString *mode = FSBarViewCfgStr(_configuration, _module, _form, @"mode", @"twoRows");
    NSString *display = FSBarViewCfgStr(_configuration, _module, _form, @"displayValue", @"oi");
    // v15：对齐 Stats SpeedPictogramColor（none/default/transparent/constant）；
    //      兼容旧布尔配置（true→default / false→none）
    NSString *valueColor = FSBarViewCfgStr(_configuration, _module, _form, @"valueColor", @"default");
    id vcRaw = FSBarViewCfgRaw(_configuration, _module, _form, @"valueColor");
    if ([vcRaw isKindOfClass:[NSNumber class]]) valueColor = [(NSNumber *)vcRaw boolValue] ? @"default" : @"none";
    NSString *iconColor = FSBarViewCfgStr(_configuration, _module, _form, @"iconColor", @"default");
    id icRaw = FSBarViewCfgRaw(_configuration, _module, _form, @"iconColor");
    if ([icRaw isKindOfClass:[NSNumber class]]) iconColor = [(NSNumber *)icRaw boolValue] ? @"default" : @"none";
    NSString *inColorKey = FSBarViewCfgStr(_configuration, _module, _form, @"downloadColor", @"secondBlue");
    NSString *outColorKey = FSBarViewCfgStr(_configuration, _module, _form, @"uploadColor", @"secondRed");
    uint64_t inV = (uint64_t)[self netIn], outV = (uint64_t)[self netOut];

    NSColor *inBase = [inColorKey isEqualToString:@"secondBlue"] ? [NSColor systemBlueColor]
                                                                 : FSBarColorFromKey(inColorKey, dark, 0);
    NSColor *outBase = [outColorKey isEqualToString:@"secondRed"] ? [NSColor systemRedColor]
                                                                  : FSBarColorFromKey(outColorKey, dark, 0);
    if (mono) { inBase = [NSColor systemBlueColor]; outBase = [NSColor systemRedColor]; }
    // SpeedPictogramColor 语义（对齐 Stats）：
    //   none=始终前景色 ｜ default=有活动(≥1KB/s)才上色 ｜ transparent=无活动透明 ｜ constant=始终上色
    NSColor *fg = FSBarTextColor(dark);
    NSColor *(^pick)(NSString *, NSColor *, uint64_t) = ^NSColor *(NSString *mode, NSColor *base, uint64_t v) {
        if ([mode isEqualToString:@"none"]) return fg;
        if ([mode isEqualToString:@"constant"]) return base;
        if ([mode isEqualToString:@"transparent"]) return v > 0 ? base : [NSColor clearColor];
        return v >= 1024 ? base : fg;   // default
    };
    NSColor *iconInC = pick(iconColor, inBase, inV);
    NSColor *iconOutC = pick(iconColor, outBase, outV);
    NSColor *valInC = pick(valueColor, inBase, inV);
    NSColor *valOutC = pick(valueColor, outBase, outV);
    NSTextAlignment ta = [align isEqualToString:@"right"] ? NSTextAlignmentRight :
                         ([align isEqualToString:@"center"] ? NSTextAlignmentCenter : NSTextAlignmentLeft);

    NSString *inStr = units ? FSSpeedStr(inV) : FSSpeedStrShort(inV);
    NSString *outStr = units ? FSSpeedStr(outV) : FSSpeedStrShort(outV);
    // v98：等宽数字——位数变化不再抖动（配合定宽 rect）
    NSFont *f = [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightLight];
    NSDictionary *inAttrs = @{NSFontAttributeName: f, NSForegroundColorAttributeName: valInC};
    NSDictionary *outAttrs = @{NSFontAttributeName: f, NSForegroundColorAttributeName: valOutC};

    CGFloat half = r.size.height / 2;
    BOOL io = [display isEqualToString:@"io"];
    BOOL iconOn = (icon && ![icon isEqualToString:@"none"]);
    // v15：图标对齐（left/right；Stats Speed iconAlignment）
    BOOL iconRight = iconOn && [FSBarViewCfgStr(_configuration, _module, _form, @"iconAlignment", @"left") isEqualToString:@"right"];
    CGFloat iconSlot = iconOn ? 8 : 0;
    CGFloat gap = FSBarConfigurationSpacing(_configuration ?: g_cfg);
    CGFloat iconX = iconRight ? MAX(0, r.size.width - iconSlot) : 0;

    if ([mode isEqualToString:@"oneRow"]) {
        // 单行两项各按实际文字宽度紧排，顺序沿用 displayValue。
        BOOL outFirst = [display hasPrefix:@"o"];
        CGFloat inWidth = [self speedValueWidth:inV], outWidth = [self speedValueWidth:outV];
        CGFloat x = iconRight || !iconOn ? 0 : iconSlot + gap;
        NSFont *vf = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        NSDictionary *iA = @{NSFontAttributeName: vf, NSForegroundColorAttributeName: valInC};
        NSDictionary *oA = @{NSFontAttributeName: vf, NSForegroundColorAttributeName: valOutC};
        if (valueOn && outFirst) {
            FSBarTextRect(outStr, oA, NSMakeRect(x, 0, outWidth, r.size.height), ta);
            x += outWidth;
            if (display.length > 1) { x += gap; FSBarTextRect(inStr, iA, NSMakeRect(x, 0, inWidth, r.size.height), ta); }
        } else if (valueOn) {
            FSBarTextRect(inStr, iA, NSMakeRect(x, 0, inWidth, r.size.height), ta);
            x += inWidth;
            if (display.length > 1) { x += gap; FSBarTextRect(outStr, oA, NSMakeRect(x, 0, outWidth, r.size.height), ta); }
        }
        [self drawSpeedIcon:icon at:iconX rect:r inC:iconInC outC:iconOutC twoRows:NO];
        return;
    }
    // 双行（Stats drawTwoRows）：displayValue 从左到右 = 从上到下
    //   "oi" → 上=Output(上传/写入) 下=Input(下载/读取)   "io" → 反
    CGFloat outY = io ? half : 0;
    CGFloat inY  = io ? 0 : half;
    CGFloat textX = iconOn && !iconRight ? iconSlot + gap : 0;
    // 两侧图标配置都先预留图标槽，右对齐文字不会覆盖右侧图标。
    CGFloat rowW = display.length == 1 ? [self speedValueWidth:[display isEqualToString:@"i"] ? inV : outV] :
        MAX([self speedValueWidth:inV], [self speedValueWidth:outV]);
    if (valueOn) {
        if (display.length == 1) {
            BOOL input = [display isEqualToString:@"i"];
            FSBarTextRect(input ? inStr : outStr, input ? inAttrs : outAttrs,
                          NSMakeRect(textX, half / 2, rowW, half), ta);
        } else {
            FSBarTextRect(outStr, outAttrs, NSMakeRect(textX, outY, rowW, half), ta);
            FSBarTextRect(inStr, inAttrs, NSMakeRect(textX, inY, rowW, half), ta);
        }
    }
    [self drawSpeedIcon:icon at:iconX rect:r inC:iconInC outC:iconOutC twoRows:YES];
}

// v101 死代码剔除：speedRowWidth（零调用的宽度助手，行宽已由 preferredWidth 定宽接管）

// 图标：dots 圆点 / arrows 箭头 / chars 字符 / none
- (void)drawSpeedIcon:(NSString *)icon at:(CGFloat)x rect:(NSRect)r inC:(NSColor *)inC outC:(NSColor *)outC twoRows:(BOOL)two {
    if (!icon || [icon isEqualToString:@"none"]) return;
    CGFloat H = r.size.height, half = H / 2;
    NSString *display = FSBarViewCfgStr(_configuration, _module, _form, @"displayValue", @"oi");
    BOOL io = [display isEqualToString:@"io"];
    BOOL single = display.length == 1, input = [display isEqualToString:@"i"];
    if ([icon isEqualToString:@"dots"]) {
        CGFloat size = two ? 6 : 8;
        x += (8 - size) / 2;
        if (single) {
            [(input ? inC : outC) setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, (H - size) / 2, size, size)] fill];
        } else if (two) {
            // Stats drawDots 换算：上圆点中心 ≈ H*0.386、下圆点中心 ≈ H*0.759（贴行底倾向）
            CGFloat topSlotY = half * 0.5;            // 5.5 @H22
            CGFloat botSlotY = half + half * 0.25;    // 13.75 @H22
            NSColor *topC = io ? inC : outC;          // displayValue 左→右 = 上→下
            NSColor *botC = io ? outC : inC;
            [topC setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, topSlotY, size, size)] fill];
            [botC setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, botSlotY, size, size)] fill];
        } else {     // 单行：两圆点上下紧凑排列
            CGFloat cy = (H - size) / 2;
            NSColor *topC = io ? inC : outC;
            NSColor *botC = io ? outC : inC;
            [topC setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, cy - 2, size, size)] fill];
            [botC setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, cy + 3, size, size)] fill];
        }
        return;
    }
    if ([icon isEqualToString:@"chars"]) {
        // Stats symbols 默认 Input="I" / Output="O"
        NSString *inSym = @"I";
        NSString *outSym = @"O";
        NSDictionary *ia = @{NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: inC};
        NSDictionary *oa = @{NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: outC};
        if (single) {
            FSBarTextRect(input ? inSym : outSym, input ? ia : oa, NSMakeRect(x, 0, 8, H), NSTextAlignmentCenter);
        } else if (two) {
            FSBarTextRect(io ? inSym : outSym, io ? ia : oa, NSMakeRect(x, 0, 8, half), NSTextAlignmentCenter);
            FSBarTextRect(io ? outSym : inSym, io ? oa : ia, NSMakeRect(x, half, 8, half), NSTextAlignmentCenter);
        } else {
            FSBarTextRect(io ? inSym : outSym, io ? ia : oa, NSMakeRect(x, 0, 8, half), NSTextAlignmentCenter);
            FSBarTextRect(io ? outSym : inSym, io ? oa : ia, NSMakeRect(x, half, 8, half), NSTextAlignmentCenter);
        }
        return;
    }
    // arrows：细箭头（Stats drawArrow 同款：竖线+箭头帽）；上=第一个显示的流向
    void (^arrow)(CGFloat, BOOL, NSColor *) = ^(CGFloat cx, BOOL up, NSColor *c) {
        CGFloat h = two ? half - 2 : H - 4;
        CGFloat top = single ? (H - h) / 2 : (two ? (up ? 1 : half + 1) : 2);
        NSBezierPath *p = [NSBezierPath bezierPath];
        CGFloat y0 = up ? top + h : top, y1 = up ? top : top + h;
        [p moveToPoint:NSMakePoint(cx, y0)];
        [p lineToPoint:NSMakePoint(cx, y1)];
        CGFloat head = 3.5;
        [p moveToPoint:NSMakePoint(cx - head, up ? y0 + head : y0 - head)];
        [p lineToPoint:NSMakePoint(cx, y0)];
        [p lineToPoint:NSMakePoint(cx + head, up ? y0 + head : y0 - head)];
        p.lineWidth = 1;
        p.lineCapStyle = NSLineCapStyleRound;
        [c setStroke];
        [p stroke];
    };
    if (single) arrow(x + 4, input, input ? inC : outC);
    else {
        arrow(x + 4, YES, io ? inC : outC);
        arrow(x + 4, NO, io ? outC : inC);
    }
}

// ======== 形态 3：bar_chart（Stats BarChart.swift） ========
- (void)drawBarChart:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    BOOL box = FSBarViewCfgBool(_configuration, _module, _form, @"box", YES);
    BOOL frame = FSBarViewCfgBool(_configuration, _module, _form, @"frame", NO);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"systemAccent");
    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    CGFloat offset = 0.5;
    CGFloat boxW = 10, boxH = r.size.height - 1;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + offset, offset, boxW, boxH) xRadius:2 yRadius:2];
    if (box) {
        [[self inverseColor:dark] setFill];
        [path fill];
    }
    double v = MIN(1.0, MAX(0.0, [self primaryValue]));
    NSColor *barC = FSBarColorFromKey(colorKey, dark, v);
    CGFloat barH = boxH * v;
    if (barH > 0.2) {
        [barC setFill];
        NSRectFill(NSMakeRect(x + offset, offset + boxH - barH, boxW, barH));
    }
    if (box || frame) {
        [[self inverseColor:dark] setStroke];
        CGFloat sc = self.window ? self.window.backingScaleFactor : 2.0;
        path.lineWidth = 1.0 / sc;
        [path stroke];
    }
}

- (NSColor *)inverseColor:(BOOL)dark { return dark ? [NSColor whiteColor] : [NSColor blackColor]; }

// ======== 形态 4：pie_chart（Stats PieChart.swift：filled 圆盘，自顶顺时针分段） ========
- (NSArray<NSDictionary *> *)pieSegments {
    NSMutableArray *segs = [NSMutableArray array];
    if ([_module isEqualToString:@"CPU"]) {
        [segs addObject:@{@"v": @(_snap.cpuUser), @"c": [NSColor systemBlueColor]}];
        [segs addObject:@{@"v": @(_snap.cpuSystem), @"c": [NSColor systemRedColor]}];
    } else if ([_module isEqualToString:@"RAM"]) {
        [segs addObject:@{@"v": @(_snap.ramAppRatio), @"c": [NSColor systemBlueColor]}];
        [segs addObject:@{@"v": @(_snap.ramWireRatio), @"c": [NSColor systemOrangeColor]}];
        [segs addObject:@{@"v": @(_snap.ramCompRatio), @"c": [NSColor systemPurpleColor]}];
    } else if ([_module isEqualToString:@"Disk"]) {
        [segs addObject:@{@"v": @(_snap.diskUsedRatio), @"c": [NSColor systemBlueColor]}];
    } else {
        double v = [self primaryValue];
        [segs addObject:@{@"v": @(v), @"c": [NSColor controlAccentColor]}];
    }
    return segs;
}

- (void)drawPie:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    BOOL mono = FSBarViewCfgBool(_configuration, _module, _form, @"monochrome", NO);
    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    CGFloat size = MIN(r.size.height, 20);
    NSPoint center = NSMakePoint(x + size / 2, r.size.height / 2);
    CGFloat radius = size / 2;
    NSArray *segs = [self pieSegments];
    double total = 0;
    for (NSDictionary *s in segs) total += [s[@"v"] doubleValue];
    CGFloat angle = 90;   // 起点：顶部
    for (NSDictionary *s in segs) {
        double v = MIN(1.0, [s[@"v"] doubleValue]);
        if (v <= 0.0005) continue;
        CGFloat next = angle - 360 * v;
        NSColor *c = s[@"c"];
        if (mono) c = FSBarGray(c);   // Stats grayscaled() 近似
        NSBezierPath *wedge = [NSBezierPath bezierPath];
        [wedge moveToPoint:center];
        [wedge appendBezierPathWithArcWithCenter:center radius:radius startAngle:angle endAngle:next clockwise:YES];
        [wedge closePath];
        [c setFill];
        [wedge fill];
        angle = next;
    }
    if (total < 0.999) {
        NSBezierPath *wedge = [NSBezierPath bezierPath];
        [wedge moveToPoint:center];
        [wedge appendBezierPathWithArcWithCenter:center radius:radius startAngle:angle endAngle:angle - 360 * (1 - total) clockwise:YES];
        [wedge closePath];
        [[[NSColor lightGrayColor] colorWithAlphaComponent:0.5] setFill];
        [wedge fill];
    }
}

// ======== 形态 5：tachometer（Stats Tachometer：半圆仪表 + 值弧） ========
- (void)drawTachometer:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    BOOL mono = FSBarViewCfgBool(_configuration, _module, _form, @"monochrome", NO);
    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    CGFloat size = MIN(r.size.height, 20);
    NSPoint center = NSMakePoint(x + size / 2, r.size.height - 2);
    CGFloat radius = size / 2 - 1.5;
    double v = MIN(1.0, MAX(0.0, [self primaryValue]));
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:center radius:radius startAngle:180 endAngle:0 clockwise:YES];
    track.lineWidth = 3;
    track.lineCapStyle = NSLineCapStyleRound;
    [[[NSColor labelColor] colorWithAlphaComponent:0.15] setStroke];
    [track stroke];
    if (v > 0.01) {
        NSBezierPath *prog = [NSBezierPath bezierPath];
        [prog appendBezierPathWithArcWithCenter:center radius:radius startAngle:180 endAngle:180 - 180 * v clockwise:YES];
        prog.lineWidth = 3;
        prog.lineCapStyle = NSLineCapStyleRound;
        NSColor *c = mono ? [self inverseColor:dark] : [NSColor controlAccentColor];
        [c setStroke];
        [prog stroke];
    }
    NSString *str = nil, *suf = nil;
    FSBarModuleValue(&_snap, _module, &str, &suf);
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: FSBarTextColor(dark)};
    FSBarTextCenter(str, attrs, x + size / 2, r.size.height - 6);
}

// ======== 形态 13：ring（环形图——整圆环 + 中心值；对比 tachometer 半圆仪表） ========
- (void)drawRing:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    BOOL mono = FSBarViewCfgBool(_configuration, _module, _form, @"monochrome", NO);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"systemAccent");
    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    CGFloat size = MIN(r.size.height, 20);
    NSPoint center = NSMakePoint(x + size / 2, r.size.height / 2);
    CGFloat radius = size / 2 - 2.2;
    double v = MIN(1.0, MAX(0.0, [self primaryValue]));
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:
                           NSMakeRect(center.x - radius, center.y - radius, radius * 2, radius * 2)];
    track.lineWidth = 3.2;
    [[[NSColor labelColor] colorWithAlphaComponent:0.15] setStroke];
    [track stroke];
    if (v > 0.008) {
        NSBezierPath *prog = [NSBezierPath bezierPath];
        [prog appendBezierPathWithArcWithCenter:center radius:radius
                                    startAngle:90 endAngle:90 - 360 * v clockwise:YES];
        prog.lineWidth = 3.2;
        prog.lineCapStyle = NSLineCapStyleRound;
        NSColor *c = mono ? [self inverseColor:dark] : FSBarColorFromKey(colorKey, dark, v);
        [c setStroke];
        [prog stroke];
    }
    NSString *str = nil, *suf = nil;
    FSBarModuleValue(&_snap, _module, &str, &suf);
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:7 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: FSBarTextColor(dark)};
    FSBarTextCenter(str, attrs, center.x, center.y + 3);
}

// ======== 形态 14：wave（波形图——平滑曲线 + 渐变填充，折线图的柔和版） ========
- (void)drawWave:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"systemAccent");
    int hc = FSBarViewCfgInt(_configuration, _module, _form, @"historyCount", 60);
    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    CGFloat w = (hc <= 30 ? 24 : (hc <= 60 ? 32 : (hc <= 90 ? 42 : 52)));
    CGFloat chartH = r.size.height - 2;
    NSColor *lineC = FSBarColorFromKey(colorKey, dark, [self primaryValue]);

    int slots = hc;
    int n = MIN(_histN, slots);
    if (n < 2 || chartH < 4) return;
    double maxV = 0;
    for (int i = _histN - n; i < _histN; i++) if (_hist[i] > maxV) maxV = _hist[i];
    BOOL ratio = FSBarModuleIsRatio(_module);
    if (maxV <= 0) maxV = 1;

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(x, 1, w, chartH));
    CGFloat dx = (w - 2) / (CGFloat)(slots - 1);
    NSMutableArray<NSValue *> *pts = [NSMutableArray array];
    for (int j = 0; j < n; j++) {
        double raw = _hist[_histN - n + j];
        double f = ratio ? MIN(1.0, raw) : MIN(1.0, raw / maxV);
        CGFloat px = x + 1 + (w - 2) - (CGFloat)(n - 1 - j) * dx;
        CGFloat py = 1 + chartH - 1 - (CGFloat)f * (chartH - 3);
        [pts addObject:[NSValue valueWithPoint:NSMakePoint(px, py)]];
    }
    // 二次贝塞尔平滑（中点法）——与折线图的硬折线区分
    NSBezierPath *wave = [NSBezierPath bezierPath];
    NSPoint p0 = pts.firstObject.pointValue;
    [wave moveToPoint:p0];
    for (NSUInteger i = 1; i + 1 < pts.count; i++) {
        NSPoint cur = pts[i].pointValue;
        NSPoint nxt = pts[i + 1].pointValue;
        NSPoint mid = NSMakePoint((cur.x + nxt.x) / 2, (cur.y + nxt.y) / 2);
        [wave curveToPoint:mid controlPoint1:cur controlPoint2:cur];
    }
    [wave lineToPoint:pts.lastObject.pointValue];
    NSBezierPath *area = [wave copy];
    CGFloat lastX = pts.lastObject.pointValue.x;
    [area lineToPoint:NSMakePoint(lastX, 1 + chartH - 0.5)];
    [area lineToPoint:NSMakePoint(p0.x, 1 + chartH - 0.5)];
    [area closePath];
    // v132：还原真实菜单栏配色（v129 的 previewBoost 提对比是失真来源——
    // 用户对比的是芯片预览 vs 真实状态栏，两者必须同色同线宽）。
    // 可读性改由渲染链解决：2x 采样 + 紧裁内容框（FSBarRenderFormPreview）。
    NSGradient *grad = [[NSGradient alloc] initWithColors:@[
        [lineC colorWithAlphaComponent:0.08],
        [lineC colorWithAlphaComponent:0.55]]];
    [grad drawInBezierPath:area angle:90];
    wave.lineWidth = 1.2;
    wave.lineJoinStyle = NSLineJoinStyleRound;
    [lineC setStroke];
    [wave stroke];
    [NSGraphicsContext restoreGraphicsState];
}

// ======== 形态 15：dots（点阵——2×4 活动点，按比例点亮） ========
- (void)drawDots:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    BOOL mono = FSBarViewCfgBool(_configuration, _module, _form, @"monochrome", NO);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"systemAccent");
    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    const int cols = 4, rows = 2;
    const int total = cols * rows;
    double v = MIN(1.0, MAX(0.0, [self primaryValue]));
    int lit = (int)llround(v * total);
    CGFloat cellW = 20.0 / cols, cellH = MIN(r.size.height, 16.0) / rows;
    CGFloat top = (r.size.height - cellH * rows) / 2;
    NSColor *on = mono ? [self inverseColor:dark] : FSBarColorFromKey(colorKey, dark, v);
    NSColor *off = [[NSColor labelColor] colorWithAlphaComponent:0.18];
    for (int i = 0; i < total; i++) {
        int row = i / cols, col = i % cols;
        CGFloat cx = x + col * cellW + cellW / 2;
        CGFloat cy = top + (rows - 1 - row) * cellH + cellH / 2;
        CGFloat d = MIN(cellW, cellH) * 0.55;
        // 自左上往右下点亮
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:
                             NSMakeRect(cx - d / 2, cy - d / 2, d, d)];
        [(i < lit ? on : off) setFill];
        [dot fill];
    }
}

// ======== 形态 16：bar（进度条——横向圆角条 + 右侧数值） ========
- (void)drawProgressBar:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"systemAccent");
    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    double v = MIN(1.0, MAX(0.0, [self primaryValue]));
    CGFloat barH = 6;
    CGFloat barY = (r.size.height - barH) / 2;
    CGFloat barW = 28;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, barY, barW, barH)
                                                          xRadius:barH / 2 yRadius:barH / 2];
    [[[NSColor labelColor] colorWithAlphaComponent:0.15] setFill];
    [track fill];
    if (v > 0.01) {
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:
                              NSMakeRect(x, barY, MAX(barH, barW * v), barH)
                                                            xRadius:barH / 2 yRadius:barH / 2];
        NSColor *c = FSBarColorFromKey(colorKey, dark, v);
        [c setFill];
        [fill fill];
    }
}

// ======== 形态 6：line_chart（Stats LineChart.swift + LineChartView，右锚定 60 槽） ========
- (void)drawLineChart:(NSRect)r dark:(BOOL)dark {
    BOOL label = ![_module isEqualToString:@"Power"] && FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    BOOL box = FSBarViewCfgBool(_configuration, _module, _form, @"box", YES);
    BOOL frame = FSBarViewCfgBool(_configuration, _module, _form, @"frame", NO);
    BOOL valueOn = ![_module isEqualToString:@"Power"] && FSBarViewCfgBool(_configuration, _module, _form, @"value", NO);
    BOOL valueColorOn = FSBarViewCfgBool(_configuration, _module, _form, @"valueColor", NO);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", [_module isEqualToString:@"Power"] ? @"monochrome" : @"systemAccent");
    int hc = FSBarViewCfgInt(_configuration, _module, _form, @"historyCount", 60);
    NSString *scale = FSBarViewCfgStr(_configuration, _module, _form, @"scale", @"none");

    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    CGFloat w = (hc <= 30 ? 24 : (hc <= 60 ? 32 : (hc <= 90 ? 42 : 52)));
    NSColor *lineC = FSBarColorFromKey(colorKey, dark, [self primaryValue]);
    NSColor *boxC = [self inverseColor:dark];

    // Stats LineChart 布局（非翻转坐标系换算）：值文本在上（占 ~9pt），盒在下（高 ≈10）
    CGFloat boxH = valueOn ? (r.size.height - 9) : r.size.height;
    CGFloat boxY = r.size.height - boxH;   // 本视图 flipped → 盒贴底
    NSBezierPath *boxPath = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 0.5, boxY + 0.5, w - 1, boxH - 1) xRadius:2 yRadius:2];
    if (box) { [boxC setFill]; [boxPath fill]; }
    if (box || frame) { [boxC setStroke]; boxPath.lineWidth = 0.5; [boxPath stroke]; }

    if (valueOn) {
        NSString *str = nil, *suf = nil;
        FSBarModuleValue(&_snap, _module, &str, &suf);
        NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightRegular],
                                NSForegroundColorAttributeName: valueColorOn ? lineC :
                                    (dark ? [NSColor whiteColor] : [NSColor blackColor])};
        FSBarTextRect(str, attrs, NSMakeRect(x + 1, 0, w - 2, 8), NSTextAlignmentRight);
    }

    // 数据（右锚定：最新在右缘；不足时从右侧生长 —— 与 LineChartView 环形缓冲一致）
    CGFloat chartH = boxH;
    int slots = hc;
    int n = MIN(_histN, slots);
    if (n < 2 || chartH < 4) return;
    double maxV = 0;
    for (int i = _histN - n; i < _histN; i++) if (_hist[i] > maxV) maxV = _hist[i];
    BOOL ratio = FSBarModuleIsRatio(_module);
    if (maxV <= 0) maxV = 1;

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(x, boxY, w, chartH));
    CGFloat dx = (w - 2) / (CGFloat)(slots - 1);
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 1;
    line.lineJoinStyle = NSLineJoinStyleRound;
    CGFloat firstX = 0, lastX = 0;
    for (int j = 0; j < n; j++) {
        double raw = _hist[_histN - n + j];
        double f;
        if (ratio) {
            f = MIN(1.0, raw);
        } else {
            f = MIN(1.0, raw / maxV);
        }
        if ([scale isEqualToString:@"square"]) f = sqrt(MAX(0, f));
        else if ([scale isEqualToString:@"cube"]) f = cbrt(MAX(0, f));
        else if ([scale isEqualToString:@"logarithmic"]) f = log(1 + MAX(0, f) * 9) / log(10);
        CGFloat px = x + 1 + (w - 2) - (CGFloat)(n - 1 - j) * dx;
        CGFloat py = boxY + chartH - 1 - (CGFloat)f * (chartH - 3);
        if (j == 0) { [line moveToPoint:NSMakePoint(px, py)]; firstX = px; }
        else [line lineToPoint:NSMakePoint(px, py)];
        if (j == n - 1) lastX = px;
    }
    NSBezierPath *area = [line copy];
    [area lineToPoint:NSMakePoint(lastX, boxY + chartH - 0.5)];
    [area lineToPoint:NSMakePoint(firstX, boxY + chartH - 0.5)];
    [area closePath];
    CGFloat baseA = box ? 0.8 : 0.5;
    NSGradient *grad = [[NSGradient alloc] initWithColors:@[
        [lineC colorWithAlphaComponent:baseA * 0.5], [lineC colorWithAlphaComponent:baseA]]];
    [grad drawInBezierPath:area angle:90];
    [lineC setStroke];
    [line stroke];
    [NSGraphicsContext restoreGraphicsState];
}

// ======== 形态 7：network_chart（Stats NetworkChart：中线上下双图） ========
- (void)drawNetworkChart:(NSRect)r dark:(BOOL)dark {
    BOOL label = FSBarViewCfgBool(_configuration, _module, _form, @"label", NO);
    BOOL box = FSBarViewCfgBool(_configuration, _module, _form, @"box", NO);
    BOOL frame = FSBarViewCfgBool(_configuration, _module, _form, @"frame", NO);
    BOOL reversed = FSBarViewCfgBool(_configuration, _module, _form, @"reversedOrder", NO);
    int hc = FSBarViewCfgInt(_configuration, _module, _form, @"historyCount", 60);       // v15：对齐 Stats
    NSString *scale = FSBarViewCfgStr(_configuration, _module, _form, @"scale", @"none"); // v15：对齐 Stats
    NSString *dKey = FSBarViewCfgStr(_configuration, _module, _form, @"downloadColor", @"secondBlue");
    NSString *uKey = FSBarViewCfgStr(_configuration, _module, _form, @"uploadColor", @"secondRed");
    NSColor *inC = [dKey isEqualToString:@"secondBlue"] ? [NSColor systemBlueColor] : FSBarColorFromKey(dKey, dark, 0);
    NSColor *outC = [uKey isEqualToString:@"secondRed"] ? [NSColor systemRedColor] : FSBarColorFromKey(uKey, dark, 0);
    if (reversed) { NSColor *t = inC; inC = outC; outC = t; }

    CGFloat x = label ? [self labelWidth] + FSBarConfigurationSpacing(_configuration ?: g_cfg) : 0;
    if (label) [self drawLabelColumn:_module at:0 dark:dark height:r.size.height];
    CGFloat w = 30;   // Stats NetworkChart：originWidth 30
    NSColor *boxC = [self inverseColor:dark];
    NSBezierPath *boxPath = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 0.5, 0.5, w - 1, r.size.height - 1) xRadius:2 yRadius:2];
    if (box) { [boxC setFill]; [boxPath fill]; }
    if (box || frame) { [boxC setStroke]; boxPath.lineWidth = 0.5; [boxPath stroke]; }

    int slots = hc;
    int n = MIN(_histN, slots);
    if (n < 2) return;
    double maxIn = 0, maxOut = 0;
    for (int i = _histN - n; i < _histN; i++) {
        if (_histIn[i] > maxIn) maxIn = _histIn[i];
        if (_histOut[i] > maxOut) maxOut = _histOut[i];
    }
    if (maxIn <= 0) maxIn = 1;
    if (maxOut <= 0) maxOut = 1;

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(x, 0, w, r.size.height));
    CGFloat dx = (w - 2) / (CGFloat)(slots - 1);
    CGFloat mid = r.size.height / 2;
    // 上行（顶部）：input/download
    NSBezierPath *topLine = [NSBezierPath bezierPath];
    NSBezierPath *botLine = [NSBezierPath bezierPath];
    topLine.lineWidth = botLine.lineWidth = 1;
    for (int j = 0; j < n; j++) {
        CGFloat px = x + 1 + (w - 2) - (CGFloat)(n - 1 - j) * dx;
        double fIn = MIN(1.0, _histIn[_histN - n + j] / maxIn);
        double fOut = MIN(1.0, _histOut[_histN - n + j] / maxOut);
        if ([scale isEqualToString:@"square"]) { fIn = sqrt(MAX(0, fIn)); fOut = sqrt(MAX(0, fOut)); }
        else if ([scale isEqualToString:@"cube"]) { fIn = cbrt(MAX(0, fIn)); fOut = cbrt(MAX(0, fOut)); }
        else if ([scale isEqualToString:@"logarithmic"]) {
            fIn = log(1 + MAX(0, fIn) * 9) / log(10);
            fOut = log(1 + MAX(0, fOut) * 9) / log(10);
        }
        CGFloat pyT = mid - 1 - (CGFloat)fIn * (mid - 2.5);
        CGFloat pyB = mid + 1 + (CGFloat)fOut * (mid - 2.5);
        if (j == 0) { [topLine moveToPoint:NSMakePoint(px, pyT)]; [botLine moveToPoint:NSMakePoint(px, pyB)]; }
        else { [topLine lineToPoint:NSMakePoint(px, pyT)]; [botLine lineToPoint:NSMakePoint(px, pyB)]; }
    }
    for (NSArray *pair in @[@[topLine, inC, @(mid)], @[botLine, outC, @(mid)]]) {
        NSBezierPath *l = pair[0];
        NSColor *c = pair[1];
        NSBezierPath *area = [l copy];
        NSRect b = [area bounds];
        [area lineToPoint:NSMakePoint(b.origin.x + b.size.width, mid)];
        [area lineToPoint:NSMakePoint(b.origin.x, mid)];
        [area closePath];
        NSGradient *grad = [[NSGradient alloc] initWithColors:@[
            [c colorWithAlphaComponent:0.45], [c colorWithAlphaComponent:0.05]]];
        [grad drawInBezierPath:area angle:(c == inC ? -90 : 90)];
        [c setStroke];
        [l stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
}

// ======== 形态 8：memory（Stats Memory.swift：F:/U: 双行） ========
- (void)drawMemory:(NSRect)r dark:(BOOL)dark {
    BOOL symbols = FSBarViewCfgBool(_configuration, _module, _form, @"symbols", YES);
    BOOL rev = FSBarViewCfgBool(_configuration, _module, _form, @"orderReversed", NO);
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"monochrome");
    NSColor *c = FSBarColorFromKey(colorKey, dark, _snap.ramRatio);
    double usedBytes = _snap.ramUsedBytes;
    double totalBytes = _snap.ramTotalBytes;
    if ([_module isEqualToString:@"Disk"]) {   // Stats Disk 的 memory 部件显示磁盘 已用/可用
        totalBytes = _snap.diskTotalBytes;
        usedBytes = MAX(0, _snap.diskTotalBytes - _snap.diskFreeBytes);
    }
    NSString *used = FSSizeStr(usedBytes);
    NSString *free = FSSizeStr(MAX(0, totalBytes - usedBytes));
    CGFloat half = r.size.height / 2;
    // Stats 非翻转：freeY = rowHeight+1（上）、usedY = 1（下）→ 本视图 flipped 换算为 F 上 / U 下
    CGFloat freeY = rev ? half : 0;
    CGFloat usedY = rev ? 0 : half;
    CGFloat x = 0;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightLight],
                            NSForegroundColorAttributeName: FSBarTextColor(dark)};
    if (symbols) {
        FSBarTextRect(@"F:", attrs, NSMakeRect(0, freeY, 8, half), NSTextAlignmentLeft);
        FSBarTextRect(@"U:", attrs, NSMakeRect(0, usedY, 8, half), NSTextAlignmentLeft);
        x = 8 + FSBarConfigurationSpacing(_configuration ?: g_cfg);
    }
    NSDictionary *vat = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightLight],
                          NSForegroundColorAttributeName: c};
    FSBarTextRect(free, vat, NSMakeRect(x, freeY, r.size.width - x, half), NSTextAlignmentRight);
    FSBarTextRect(used, vat, NSMakeRect(x, usedY, r.size.width - x, half), NSTextAlignmentRight);
}

// ======== 形态 9：battery（Stats Battery.swift：电池壳 + 内填充 + 文本） ========
// v129（内存）：SF Symbol 图像静态缓存——drawBattery/drawIcon 在每次 drawRect
// （部件按 updateInterval 每 0.5~1s 重绘）都新建 NSImage(systemSymbolName:) +
// imageWithSymbolConfiguration，每次重建都触发 CoreSVG 解码（heap：SVGAttribute
// 27K 个 + SVGPathCommand 23K 个 + CGPath 1.6K 个 ≈ 3.8MB 就是这批符号渲染产物）。
// 符号内容只依赖 (符号名, 字号, 字重)，缓存后整个 tick 周期零解码。
static NSImage *FSBarSymbolImage(NSString *sym, CGFloat pointSize, NSFontWeight weight) {
    static NSMutableDictionary<NSString *, NSImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%.1f", sym, pointSize, (double)weight];
    NSImage *img = cache[key];
    if (img) return img;
    img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight]];
    if (img) cache[key] = img;
    return img;
}

- (void)drawBattery:(NSRect)r dark:(BOOL)dark {
    NSString *disp = FSBarViewCfgStr(_configuration, _module, _form, @"display", @"percentage");
    NSString *colorKey = FSBarViewCfgStr(_configuration, _module, _form, @"color", @"systemAccent");
    double p = MIN(1.0, MAX(0.0, _snap.batteryPercent / 100.0));
    CGFloat W = 22, Hh = 12;
    CGFloat x = 0;
    CGFloat y = (r.size.height - Hh) / 2;
    // 电池壳
    NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 0.5, y + 0.5, W, Hh) xRadius:2 yRadius:2];
    [[FSBarTextColor(dark) colorWithAlphaComponent:0.5] setStroke];
    shell.lineWidth = 1;
    [shell stroke];
    // 电池头
    NSBezierPath *tip = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + W + 1, y + Hh / 2 - 2, 2, 4) xRadius:1 yRadius:1];
    [[FSBarTextColor(dark) colorWithAlphaComponent:0.5] setFill];
    [tip fill];
    // 内填充
    NSColor *fill;
    if ([colorKey isEqualToString:@"systemAccent"]) fill = [NSColor controlAccentColor];
    else fill = FSBarColorFromKey(colorKey, dark, p);
    CGFloat innerW = MAX(1, (W - 4) * p);
    NSBezierPath *inner = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 2, y + 2, innerW, Hh - 4) xRadius:1 yRadius:1];
    [fill setFill];
    [inner fill];
    if (_snap.batteryPresent && _snap.batteryCharging) {
        NSImage *bolt = FSBarSymbolImage(@"bolt.fill", 8, NSFontWeightSemibold);
        [FSBarTextColor(dark) set];
        [bolt drawInRect:NSMakeRect(x + 8, y, 8, Hh) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.8 respectFlipped:YES hints:nil];
    }
    x += 25 + FSBarConfigurationSpacing(_configuration ?: g_cfg);
    // 文本行
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightLight],
                            NSForegroundColorAttributeName: FSBarTextColor(dark)};
    if (!_snap.batteryPresent) {
        if (![disp isEqualToString:@"none"]) FSBarTextCenter(@"—", attrs, x, r.size.height / 2);
        return;
    }
    if ([disp isEqualToString:@"none"]) return;   // v15：对齐 Stats BatteryAdditionals（None）
    NSString *pct = [NSString stringWithFormat:@"%.0f%%", _snap.batteryPercent];
    NSString *time = FSRemainStr(_snap.batteryRemainMin);
    if ([disp isEqualToString:@"time"]) {
        FSBarTextCenter(time, attrs, x, r.size.height / 2);
    } else if ([disp isEqualToString:@"percentageAndTime"] || [disp isEqualToString:@"timeAndPercentage"]) {
        CGFloat half = r.size.height / 2;
        BOOL pctFirst = [disp isEqualToString:@"percentageAndTime"];
        FSBarTextCenter(pctFirst ? pct : time, attrs, x, half * 0.5);
        FSBarTextCenter(pctFirst ? time : pct, attrs, x, half + half * 0.5);
    } else {
        FSBarTextCenter(pct, attrs, x, r.size.height / 2);
    }
}

// ======== 形态 10：state（Stats Dot：8px 圆点） ========
- (void)drawState:(NSRect)r dark:(BOOL)dark {
    NSColor *c = [NSColor systemGreenColor];
    if ([_module isEqualToString:@"Network"]) {
        BOOL active = _snap.netDownBps >= 1024 || _snap.netUpBps >= 1024;
        c = active ? [NSColor systemGreenColor] : [FSBarTextColor(dark) colorWithAlphaComponent:0.6];
    } else if ([_module isEqualToString:@"Battery"]) {
        double p = _snap.batteryPercent;
        c = p > 20 ? [NSColor systemGreenColor] : (p > 10 ? [NSColor systemYellowColor] : [NSColor systemRedColor]);
    } else if ([_module isEqualToString:@"Disk"]) {
        c = [NSColor systemGreenColor];
    }
    CGFloat size = 8;
    [c setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, (r.size.height - size) / 2, size, size)] fill];
}

// ======== 形态 11：icon（Stats IconWidget：SF Symbol，14pt） ========
- (void)drawIcon:(NSRect)r dark:(BOOL)dark {
    // v98（2026-10-21 用户：「状态栏图标显示看不太清晰」）：
    // 14pt Regular 小符号发虚——改 15pt Semibold + 模板着色（跟随前景色），
    // 深浅色都清晰；预览图（FSBarRenderFormPreview）同源自动受益。
    // v129（内存）：符号图像走 FSBarSymbolImage 静态缓存（每 drawRect 重建
    // 是 CoreSVG 解码churn 的最大来源，见缓存实现处注释）。
    NSString *sym = FSBarViewCfgStr(_configuration, _module, _form, @"icon", [self defaultSymbol]);
    NSImage *img = FSBarSymbolImage(sym, 15, NSFontWeightSemibold);
    img.template = YES;
    if ([_module isEqualToString:@"Power"]) {
        NSColor *color = FSBarColorFromKey(FSBarViewCfgStr(_configuration, _module, _form, @"color", @"monochrome"), dark, [self primaryValue]);
        img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
        img.template = NO;
    }
    NSSize sz = img.size;
    NSPoint p = NSMakePoint((r.size.width - sz.width) / 2, (r.size.height - sz.height) / 2);
    [FSBarTextColor(dark) set];
    [img drawInRect:NSMakeRect(p.x, p.y, sz.width, sz.height) fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (NSString *)defaultSymbol {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"CPU": @"cpu", @"RAM": @"memorychip", @"GPU": @"display",
                @"Disk": @"internaldrive", @"Network": @"arrow.up.arrow.down",
                @"Sensors": @"thermometer.medium", @"Battery": @"battery.100",
                @"Power": @"bolt.fill", @"CPUPower": @"cpu", @"GPUPower": @"display"};
    });
    return map[_module] ?: @"gearshape";
}

@end

// ======== v32/v34/v35 移植（注入版）：奔跑小猫 —— static 实现区 ========
static NSStatusItem *FSFindMainBarItem(void);   // 前向声明（定义于状态项管理器区）

static NSImage *FSRunCatImage(int idx, FSRunCatImageVariant variant) {
    if (!g_runCatImgs) g_runCatImgs = [NSMutableDictionary dictionary];
    NSNumber *key = @(variant * frset_runcat_frame_count() + idx);
    NSImage *img = g_runCatImgs[key];
    if (img) return img;
    if (variant == FSRunCatImageTemplate) {
        // 状态栏原生按钮复用自己的模板帧，预览继续使用原尺寸和原色。
        img = [FSRunCatImage(idx, FSRunCatImageBlack) copy];
        img.size = NSMakeSize(20 * 56.0 / 36.0, 20);
        img.template = YES;
    } else {
        unsigned int len = 0;
        const unsigned char *data = frset_runcat_frame(idx, variant == FSRunCatImageWhite, &len);
        if (!data || len == 0) return nil;
        img = [[NSImage alloc] initWithData:[NSData dataWithBytes:data length:len]];
    }
    if (img) g_runCatImgs[key] = img;
    return img;
}

@implementation FSRunCatIconView
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)p { (void)p; return nil; }   // 点击穿透到 button（保持原 action）
- (void)stopPreview {
    [self.previewTimer invalidate];
    self.previewTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
- (void)updatePreviewAnimation:(NSNotification *)notification {
    if (!self.fixedFrame) return; // 正式猫仍由全局帧推进。
    if ([notification.name isEqualToString:NSWindowWillCloseNotification]) {
        // 关闭停止播放；观察在视图脱离窗口时统一移除。
        [self.previewTimer invalidate];
        self.previewTimer = nil;
        return;
    }
    BOOL animate = self.window.isVisible && (self.window.occlusionState & NSWindowOcclusionStateVisible)
        && !self.isHiddenOrHasHiddenAncestor && !NSIsEmptyRect(self.visibleRect)
        && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (!animate) {
        [self.previewTimer invalidate];
        self.previewTimer = nil;
    } else if (!self.previewTimer) {
        __weak FSRunCatIconView *weakSelf = self;
        self.previewTimer = [NSTimer timerWithTimeInterval:1.0 / 8.0 repeats:YES block:^(NSTimer *timer) {
            FSRunCatIconView *view = weakSelf;
            [view updatePreviewAnimation:nil];
            if (!view.previewTimer) return;
            view.fixedFrame = @((view.fixedFrame.intValue + 1) % frset_runcat_frame_count());
            view.needsDisplay = YES;
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.previewTimer forMode:NSRunLoopCommonModes];
    }
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.fixedFrame) return;
    [self stopPreview];
    if (!self.window) return;
    for (NSNotificationName name in @[NSWindowDidChangeOcclusionStateNotification, NSWindowWillCloseNotification])
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatePreviewAnimation:)
            name:name object:self.window];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(updatePreviewAnimation:)
        name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    [self updatePreviewAnimation:nil];
}
- (void)viewDidHide { [super viewDidHide]; [self updatePreviewAnimation:nil]; }
- (void)viewDidUnhide { [super viewDidUnhide]; [self updatePreviewAnimation:nil]; }
- (void)dealloc { [self stopPreview]; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [self updatePreviewAnimation:nil];
    NSImage *img = FSRunCatImage(self.fixedFrame ? self.fixedFrame.intValue : g_runCatFrame,
                                FSBarDark(self) ? FSRunCatImageWhite : FSRunCatImageBlack);
    if (!img) return;
    NSRect r = self.bounds;
    // v82：按高度定尺寸（56:36），但**不得超过按钮可用宽度**——原实现固定 56:36，
    // 在 custom/logo 的 variableLength 按钮（约 20-24pt）上会被裁掉头/尾。
    CGFloat h = MAX(1, r.size.height - 2);
    CGFloat w = h * 56.0 / 36.0;
    if (w > r.size.width) {
        w = MAX(1, r.size.width);
        h = w * 36.0 / 56.0;
    }
    NSRect dr = NSMakeRect(r.origin.x + (r.size.width - w) / 2.0,
                           r.origin.y + (r.size.height - h) / 2.0, w, h);
    [img drawInRect:dr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
           fraction:1 respectFlipped:YES hints:nil];
}
@end

// 2026-11-16：用户反复反馈小猫旁的可点击空白；主按钮直接显示真实帧，取消空图覆盖层。
static void FSRunCatUpdateMainIcon(void) {
    NSStatusItem *main = FSFindMainBarItem();
    if (!main || !main.button) return;
    NSButton *b = main.button;
    if (b.title.length != 0) b.title = @"";
    if (b.imagePosition != NSImageOnly) b.imagePosition = NSImageOnly;
    if (b.imageScaling != NSImageScaleProportionallyDown) {
        b.imageScaling = NSImageScaleProportionallyDown;
    }
    b.image = FSRunCatImage(g_runCatFrame, FSRunCatImageTemplate);
    if (main.length != 34) main.length = 34;
    g_mainIconCatLastFrame = g_runCatFrame;
}

// v85：运行时开关（设置窗「菜单栏图标 · 小猫」用）
BOOL FSRunCatIconEnabled(void) { return g_mainIconCatEnabled; }
void FSRunCatIconSetEnabled(BOOL on) {
    FSBarCfgSet(@"Bar", nil, @"MainIconCat", @(on));
    FSRunCatIconApplySavedConfiguration();
}
void FSRunCatIconApplySavedConfiguration(void) {
    BOOL on = FSBarAsBool(FSBarCfgRaw(@"Bar", nil, @"MainIconCat"), NO);
    g_mainIconCatEnabled = on;
    g_mainIconCatInited = YES;
    if (!on) {
        NSStatusItem *main = FSFindMainBarItem();
        main.length = NSVariableStatusItemLength;                  // v82：恢复原宽度
        [[NSNotificationCenter defaultCenter] postNotificationName:@"FrsetRunCatIconChanged" object:nil];
        FSBarLog(@"[mainicon] 小猫关 → 恢复官方图标");
    } else {
        FSRunCatStartTimer();
        FSRunCatUpdateMainIcon();
        FSBarLog(@"[mainicon] 小猫开 → 原生主按钮图像（34pt）");
    }
}

static void FSRunCatTick(void) {
    // v34：懒初始化开关（plist 键 MainIconCat；缺省=开；环境变量 FRSET_MAINICON_CAT 可覆盖——测试用）
    if (!g_mainIconCatInited) {
        g_mainIconCatInited = YES;
        const char *env = getenv("FRSET_MAINICON_CAT");
        if (env && *env) {
            g_mainIconCatEnabled = (atoi(env) != 0);
        } else {
            // v82 修正：开关由 FSBarCfgSet(@"Bar", nil, @"MainIconCat") 写入，
            // 实际键名是 Bar_MainIconCat；原读取用 FSBarGlobalRaw(@"MainIconCat")
            // 永远读到 nil → 重启后小猫默认关闭（设置里勾着但菜单栏没猫）。
            id v = FSBarCfgRaw(@"Bar", nil, @"MainIconCat");
            if ([v isKindOfClass:[NSNumber class]]) g_mainIconCatEnabled = [v boolValue];
        }
    }
    if (!g_mainIconCatEnabled) {
        FSRunCatStopTimer();
        return;
    }

    double cpu = g_snap.valid ? g_snap.cpuUsage : 0;
    if (cpu < 0) cpu = 0;
    if (cpu > 1) cpu = 1;
    // v82（用户：小猫有两套时间）：速度档只在 **CPU 部件刷新时刻**更新一次
    // （FSBarModuleInterval(@"CPU")，当前 3s），与菜单栏 CPU 数值同一节奏；
    // 10Hz 定时器推进动画帧；速度档只在 CPU 样本刷新时改变。
    double now = CFAbsoluteTimeGetCurrent();
    static double g_runCatLastSpeedAt = 0;
    double speedIv = FSBarModuleInterval(@"CPU");
    if (g_runCatLastSpeedAt <= 0 || now - g_runCatLastSpeedAt >= speedIv) {
        g_runCatLastSpeedAt = now;
        g_runCatCpuEMA = g_runCatCpuEMA * 0.6 + cpu * 0.4;
    }
    // v78：完整循环 + 倍速 —— 基础 8fps 完整播放 5 帧跑步循环，
    //   CPU 负载只改变播放倍速，帧间隔恒定不再忽快忽慢卡顿
    static double g_runCatProgress = 0;    // 累计播放进度（秒）
    static double g_runCatLastTick = 0;
    double dt = (g_runCatLastTick > 0) ? (now - g_runCatLastTick) : 0;
    g_runCatLastTick = now;
    if (dt > 0.5) dt = 0.5;                // 防休眠后跳帧
    // v80：倍速分 7 档（离散，避免连续变化导致步频抖动）；素材 5 帧，每 tick 最多推进 2 帧不跳帧
    // v81：倍速压到 0.5~1.5×（用户：不要太高）
    double m = 0.5;
    double c = g_runCatCpuEMA;
    if (c < 0.10)      m = 0.5;
    else if (c < 0.25) m = 0.7;
    else if (c < 0.40) m = 0.9;
    else if (c < 0.55) m = 1.0;
    else if (c < 0.70) m = 1.1;
    else if (c < 0.85) m = 1.3;
    else               m = 1.5;
    g_runCatProgress += dt * m;
    double step = 1.0 / 8.0;               // 基础 8fps
    if (g_runCatProgress > step * 2) g_runCatProgress = step * 2;   // 每 tick 最多 2 帧（防跳帧）
    while (g_runCatProgress >= step) {
        g_runCatProgress -= step;
        g_runCatFrame = (g_runCatFrame + 1) % frset_runcat_frame_count();
    }
    // v71：合并条 run_cat 已移除，帧推进仅服务主图标覆盖层

    NSStatusItem *main = FSFindMainBarItem();
    if (main && (g_runCatFrame != g_mainIconCatLastFrame || !main.button.image)) {
        FSRunCatUpdateMainIcon();
    }
}

static void FSRunCatStartTimer(void) {
    if (g_runCatTimer) return;
    g_runCatTimer = [NSTimer timerWithTimeInterval:0.10 repeats:YES block:^(NSTimer *tm) { FSRunCatTick(); }];
    [[NSRunLoop mainRunLoop] addTimer:g_runCatTimer forMode:NSRunLoopCommonModes];
    FSBarLog(@"[runcat] 奔跑小猫动画定时器已启动（主图标 10Hz）");
}

static void FSRunCatStopTimer(void) {
    [g_runCatTimer invalidate];
    g_runCatTimer = nil;
}

// ============ 状态项管理器 ============

static NSMutableArray *g_statusItems = nil;      // inject 传入（原生项捕获）
static NSStatusItem *g_mainItemRef = nil;        // v30：重建版主图标项（外部注入；见 FSBarSetMainItem）

// v34 移植（注入版）：找主图标项。
//   注入版口径：Item-0 优先 → 首个非 frset.* 前缀项；
//   重建版适配：外部注册的主图标项（frsetnext.main）优先，其余口径保留兜底。
static NSStatusItem *FSFindMainBarItem(void) {
    if (g_mainItemRef && g_mainItemRef.button) return g_mainItemRef;
    for (NSStatusItem *it in g_statusItems) {
        if ([it.autosaveName isEqualToString:@"Item-0"]) return it;
    }
    for (NSStatusItem *it in g_statusItems) {
        NSString *n = it.autosaveName ?: @"";
        if (![n hasPrefix:@"frset."]) return it;
    }
    return nil;
}
static NSMutableDictionary<NSString *, NSStatusItem *> *g_ownItems = nil;   // "module/form" → 自建项
// g_views 定义已提前至 FSBarWidgetView @interface 之后（v32 小猫定时器需引用）
static NSMutableDictionary<NSString *, NSStatusItem *> *g_nativeItems = nil;// module → 原生项
static int g_tickN = 0;
static NSString *FSBarGlobalStr(NSString *key, NSString *def);   // 前向声明（位置代码引用）
static NSStatusItem *g_mergedItem = nil;   // v11：合并显示项（CombinedModules）
static NSView *g_mergedView = nil;         // v11：合并容器（紧排所有模块部件）

@interface FSBarManager : NSObject
// v28：合并条右键菜单（部件样式切换 / 分隔线 / 间距 / 打开面板）
- (void)mergedMenuOpenSettings:(NSMenuItem *)item;
- (void)mergedMenuOpenPanel:(NSMenuItem *)item;
@end
static FSBarManager *g_manager = nil;

// 前向声明（菜单/重建引用；定义于文件后部）
static void FSBarReconcile(void);
void FSBarDebugCharProbe(void);   // v28：合并条位置/内容探针（FRSET_BARCHAR=1）

// 右键中的持久参数定位到总设置，不再直接写部件配置。
static void FSBarShowMergedMenu(NSString *hitModule, NSPoint at) {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    NSMenuItem *configuration = [[NSMenuItem alloc]
        initWithTitle:hitModule ? [NSString stringWithFormat:@"配置 %@ 部件…", FSBarModuleName(hitModule)] : @"部件与颜色…"
        action:@selector(mergedMenuOpenSettings:) keyEquivalent:@""];
    configuration.target = g_manager;
    configuration.representedObject = hitModule ? [@"menubar.widgets#" stringByAppendingString:hitModule] : @"menubar.widgets";
    [menu addItem:configuration];
    NSMenuItem *arrangement = [[NSMenuItem alloc] initWithTitle:@"排列与间距…"
        action:@selector(mergedMenuOpenSettings:) keyEquivalent:@""];
    arrangement.target = g_manager;
    arrangement.representedObject = @"menubar.arrangement";
    [menu addItem:arrangement];

    [menu addItem:[NSMenuItem separatorItem]];
    {
        NSString *title = hitModule ? [NSString stringWithFormat:@"打开 %@ 面板", FSBarModuleName(hitModule)]
                                    : @"打开性能面板";
        NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(mergedMenuOpenPanel:)
                                               keyEquivalent:@""];
        open.target = g_manager;
        open.representedObject = hitModule;
        [menu addItem:open];
    }

    if (g_mergedView) [menu popUpMenuPositioningItem:nil atLocation:at inView:g_mergedView];
}

@implementation FSBarManager
// v14 修正：按钮动作的发送者恒为 NSStatusBarButton（不是 NSStatusItem）——两种类型均兼容比对
// v46：独立项点击也记录锚点（与 openMerged 同源）——面板贴被点图标展开
- (void)openItem:(id)sender {
    NSString *m = nil;
    NSStatusItem *hitItem = nil;
    for (NSString *k in g_ownItems) {
        NSStatusItem *it = g_ownItems[k];
        if (it == sender || it.button == sender) { m = [k componentsSeparatedByString:@"/"][0]; hitItem = it; break; }
    }
    if (m) {
        if (hitItem.button.window) {
            g_anchorScreen = [hitItem.button.window convertRectToScreen:hitItem.button.bounds];
        }
        FSBarOpenMonitor(FSBarModuleIndex(m));
    }
    else FSBarLog(@"openItem: 发送者未匹配（%@）", NSStringFromClass([sender class]));
}

// v24：最近一次点击的菜单栏锚点（屏幕坐标，1×1）—— 面板据此在"图标位置"展开，
//   而不是永远贴屏幕右侧（原版固定定位）。由合并条点击处写入，注入层读取。
static NSRect g_anchorScreen = {{0, 0}, {0, 0}};
NSRect FSBarLastAnchorScreenRect(void) { return g_anchorScreen; }
void FSBarSetDebugAnchorX(CGFloat x) { g_anchorScreen = NSMakeRect(x, 0, 1, 1); }

// v14：合并项点击 → 按点击 x 分派模块（对齐 Stats CombinedView.openModulePopup：
//   last(where: minX <= x) ?? first）
//   注意：sender 恒为 NSStatusBarButton；旧实现直接把 sender 当 NSStatusItem 调 .button，
//   而 NSStatusBarButton 不响应 button 选择器（实测 respondsTo=0）——真机动作一旦触发即抛异常。
- (void)openMerged:(id)sender {
    if (!g_mergedView) return;
    NSWindow *win = nil;
    if ([sender isKindOfClass:[NSView class]]) win = [(NSView *)sender window];
    else if ([sender isKindOfClass:[NSStatusItem class]]) win = ((NSStatusItem *)sender).button.window;
    if (!win) win = g_mergedItem.button.window;
    NSPoint p = [NSEvent mouseLocation];
    // v52：菜单栏状态项窗口的 AppKit 屏幕坐标不可靠（实测 win.frame 比窗口服务器的真实
    //   位置偏 24pt，导致点击 SSD 命中 CPU；事件 locationInWindow 又恒为按钮中心）。
    //   改用 CGWindowList 的窗口 bounds —— 与截图同一坐标系；内边距按
    //   (窗口宽 - 合并视图宽)/2 补偿。CG 查询失败时退回 AppKit 换算。
    if (win && g_mergedView) {
        CGFloat winX = NSMinX(win.frame);
        CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                                                    (CGWindowID)win.windowNumber);
        if (arr) {
            if (CFArrayGetCount(arr) > 0) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, 0);
                NSDictionary *bounds = info[(id)kCGWindowBounds];
                if (bounds[@"X"]) winX = [bounds[@"X"] doubleValue];
            }
            CFRelease(arr);
        }
        CGFloat inset = MAX(0.0, (NSWidth(win.frame) - NSWidth(g_mergedView.frame)) / 2.0);
        // macOS 26：菜单栏项 NSWindow.frame 比真实绘制位置右移 32pt（实测：窗口 frame
        //   x=1140 / 宽 168，而屏幕截图上部件内容从 1116 开始、右缘 1266 —— 用 frame
        //   命中会整体偏一个部件）。此处按实测常量回补；若未来系统修正该偏差，
        //   命中会在 ±32pt 内错位，届时把该常量改为 0。
        static const CGFloat kStatusItemFrameDX = 32.0;
        p = NSMakePoint(p.x - (winX - kStatusItemFrameDX) - inset, NSMidY(g_mergedView.bounds));
    } else {
        if (win) p = [win convertPointFromScreen:p];
        p = [g_mergedView convertPoint:p fromView:nil];
    }
    NSString *target = nil;
    for (NSString *m in FSBarAllModules()) {
        NSArray *forms = FSBarEnabledForms(m);
        if (!forms.count) continue;
        FSBarWidgetView *w = g_views[[NSString stringWithFormat:@"%@/%@", m, forms[0]]];
        if (!w || w.superview != g_mergedView) continue;
        if (!target || w.frame.origin.x <= p.x + 0.5) target = m;
    }
    // v28：右键（或 Control+左键）→ 弹出部件样式菜单（Stats 式快速切换）
    {
        NSEvent *ev = NSApp.currentEvent;
        BOOL ctx = ev && (ev.type == NSEventTypeRightMouseDown ||
                          (ev.type == NSEventTypeLeftMouseDown && (ev.modifierFlags & NSEventModifierFlagControl)));
        if (ctx) {
            FSBarLog(@"[barmenu] 右键菜单 x=%.1f hit=%@", p.x, target ?: @"(空)");
            FSBarShowMergedMenu(target, NSMakePoint(MAX(0, p.x), 0));
            return;
        }
    }
    // v24：记录锚点 —— 用"点击位置所在部件"的屏幕 x（更贴近用户直觉：点到哪个部件就从哪展开）
    // v52：直接用鼠标屏幕 x（与命中测试同一来源），不再经 AppKit 窗口换算——后者在菜单栏
    //   窗口上有 24pt 系统偏差，会把面板锚点带偏。
    {
        CGFloat screenX = [NSEvent mouseLocation].x;
        if (screenX > 0) {
            g_anchorScreen = NSMakeRect(screenX, 0, 1, 1);
        } else if (g_mergedView.window) {
            NSPoint inWin = [g_mergedView convertPoint:NSMakePoint(p.x, NSMidY(g_mergedView.bounds)) toView:nil];
            NSRect sr = [g_mergedView.window convertRectToScreen:NSMakeRect(inWin.x, inWin.y, 1, 1)];
            g_anchorScreen = NSMakeRect(sr.origin.x, 0, 1, 1);
        }
    }
    FSBarLog(@"合并项点击 x=%.1f → %@（event=%ld）", p.x, target ?: @"(未分派)",
             (long)(NSApp.currentEvent ? NSApp.currentEvent.type : -1));
    if (target) FSBarOpenMonitor(FSBarModuleIndex(target));
}

- (void)mergedMenuOpenSettings:(NSMenuItem *)item {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FrsetStatsBarOpenSettings" object:item.representedObject];
}

- (void)mergedMenuOpenPanel:(NSMenuItem *)item {
    NSString *m = [item.representedObject isKindOfClass:[NSString class]] ? item.representedObject : nil;
    FSBarOpenMonitor(m ? FSBarModuleIndex(m) : 0);
}
@end

// ============ v11：合并显示（对齐 Stats CombinedView / CombinedModules） ============

// 点击穿透视图（容器不拦截点击，落到状态栏按钮）
@interface FSBarMergedView : NSView @end
@implementation FSBarMergedView
- (NSView *)hitTest:(NSPoint)p { return nil; }
@end

// 1pt 分隔线（Stats SeparatorLineView；穿透点击）
@interface FSBarSepView : NSView
@property (nonatomic, copy) NSString *colorKey;
@end
@implementation FSBarSepView
- (NSView *)hitTest:(NSPoint)p { return nil; }
- (void)drawRect:(NSRect)dirty {
    // Stats SeparatorLineView：深色=白线 / 浅色=黑线
    BOOL dark = FSBarDark(self);
    [FSBarColorFromKey(self.colorKey ?: @"monochrome", dark, 0) setFill];
    NSRectFill(self.bounds);
}
@end

// 引擎日志落盘（诊断用：~/Library/Application Support/FrsetStats/engine.log）
// 低频写：启动 / 结构变化 / 布局宽度变化时各一行；>200KB 时截断重置。
// v18：改为非 static 导出（frset_stats_inject.m 的 OPENCHK 等探针复用）。
void FSBarLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *path = [FSBarStorePath() stringByDeletingLastPathComponent];
    path = [path stringByAppendingPathComponent:@"engine.log"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [NSDate dateWithTimeIntervalSince1970:CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970], msg];
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attr fileSize] > 200 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @catch (NSException *e) {}
    [fh closeFile];
}

// 状态项位置保持（Stats restoreNSStatusItemPosition/saveNSStatusItemPosition 同款机制）
static void FSBarPositionRestore(NSString *ident) {
    FSBarLoadStore();
    NSNumber *prev = g_cfg[[@"NSPos_" stringByAppendingString:ident]];
    if ([prev isKindOfClass:[NSNumber class]]) {
        [[NSUserDefaults standardUserDefaults] setObject:prev
                  forKey:[@"NSStatusItem Preferred Position " stringByAppendingString:ident]];
    }
}
static void FSBarPositionSave(NSString *ident) {
    if (!ident) return;
    FSBarLoadStore();
    NSNumber *cur = [[NSUserDefaults standardUserDefaults] objectForKey:
        [@"NSStatusItem Preferred Position " stringByAppendingString:ident]];
    if ([cur isKindOfClass:[NSNumber class]]) {
        g_cfg[[@"NSPos_" stringByAppendingString:ident]] = cur;
        FSBarSaveStore();
    }
}

static CGFloat FSBarLayoutWidgets(NSView *container, NSArray<FSBarWidgetView *> *widgets,
                                  CGFloat spacing, BOOL separator, NSString *color) {
    NSMutableArray<FSBarSepView *> *lines = [NSMutableArray array];
    for (NSView *view in [container.subviews copy]) {
        if ([view isKindOfClass:FSBarSepView.class]) [lines addObject:(FSBarSepView *)view];
        else if (![view isKindOfClass:FSBarWidgetView.class]) [view removeFromSuperview];
    }
    NSUInteger usedLines = 0;
    CGFloat x = 0, height = container.frame.size.height;
    for (FSBarWidgetView *widget in widgets) {
        if (x > 0) {
            if (separator) {
                NSRect frame = NSMakeRect(x + spacing / 2, 3, 1, height - 6);
                FSBarSepView *line = usedLines < lines.count ? lines[usedLines] : [[FSBarSepView alloc] initWithFrame:frame];
                usedLines++;
                if (!NSEqualRects(line.frame, frame)) line.frame = frame;
                if (![line.colorKey isEqualToString:color]) {
                    line.colorKey = color;
                    line.needsDisplay = YES;
                }
                if (line.superview != container) [container addSubview:line];
                x += 1;
            }
            x += spacing;
        }
        CGFloat width = MAX(1, [widget preferredWidth]);
        NSRect frame = NSMakeRect(x, 0, width, height);
        if (!NSEqualRects(widget.frame, frame)) widget.frame = frame;
        if (widget.superview != container) [container addSubview:widget];
        x += width;
    }
    for (NSUInteger index = usedLines; index < lines.count; index++) [lines[index] removeFromSuperview];
    NSRect frame = NSMakeRect(0, 0, MAX(x, 1), height);
    if (!NSEqualRects(container.frame, frame)) container.frame = frame;
    return MAX(x, 1);
}

// 合并布局（对齐 Stats CombinedView.recalculate）：
//   相邻部件间距只计算一次；分隔线额外占1pt，空隙均分到两侧。
static void FSBarMergedLayout(void) {
    if (!g_mergedItem || !g_mergedView) return;
    CGFloat spacing = FSBarMergedSpacing();
    BOOL sep = FSBarMergedSeparator();
    NSMutableArray *widgets = [NSMutableArray array];
    for (NSString *module in FSBarOrderedModules(g_cfg))
        for (NSString *form in FSBarEnabledForms(module)) {
            FSBarWidgetView *widget = g_views[[NSString stringWithFormat:@"%@/%@", module, form]];
            if (widget) [widgets addObject:widget];
        }
    CGFloat x = FSBarLayoutWidgets(g_mergedView, widgets, spacing, sep,
                                   FSBarGlobalStr(@"CombinedModules_separatorColor", @"monochrome"));
    if (fabs(g_mergedItem.length - x) > 0.5) g_mergedItem.length = x;

    // 布局宽度变化时留痕（明细：模块/形态=宽度）
    // v137（性能审计）：FSBarLog 是**同步写盘**——流量数字每几秒变化一次宽度就
    // 触发一次写，长期运行时是稳定的小额阻塞。节流到 ≥5s 一条（诊断足够用）。
    static CGFloat lastTotal = -1;
    static CFAbsoluteTime lastLogAt = 0;
    if (fabs(lastTotal - x) > 0.5) {
        lastTotal = x;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastLogAt >= 5.0) {
            lastLogAt = now;
            NSMutableArray *parts = [NSMutableArray array];
            for (NSString *m in FSBarAllModules()) {
                NSArray *forms = FSBarEnabledForms(m);
                if (!forms.count) continue;
                FSBarWidgetView *w = g_views[[NSString stringWithFormat:@"%@/%@", m, forms[0]]];
                if (w) [parts addObject:[NSString stringWithFormat:@"%@/%@=%.0f", m, forms[0], w.frame.size.width]];
            }
            FSBarLog(@"合并布局 总宽=%.0fpt（spacing=%.0f sep=%d）: %@",
                     x, FSBarMergedSpacing(), FSBarMergedSeparator(), [parts componentsJoinedByString:@" "]);
        }
    }
}

// 创建合并项（幂等；创建前恢复偏好位置）
static void FSBarEnsureMergedItem(void) {
    if (g_mergedItem) return;
    // 清掉旧校准留下的固定位置，长度变化交由系统菜单栏排布。
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NSStatusItem Preferred Position frset.bar.merged"];
    g_mergedItem = [[NSStatusBar systemStatusBar] statusItemWithLength:0];
    g_mergedItem.autosaveName = @"frset.bar.merged";
    g_mergedView = [[FSBarMergedView alloc] initWithFrame:NSMakeRect(0, 0, 1, 22)];
    NSButton *btn = g_mergedItem.button;
    if (btn) {
        btn.image = [NSImage new];   // 清掉默认图像（Stats 同款）
        btn.toolTip = @"性能监测（合并显示）";
        btn.target = g_manager;
        btn.action = @selector(openMerged:);
        // ★ v14 根因修复（对齐 Stats CombinedView.swift:81 / widget.swift:357）：
        //   自定义状态项必须显式指定"按下即派发"——默认 mouseUp 派发会被空内容按钮
        //   的状态栏跟踪取消，导致真实点击毫无反应（performClick 因绕过跟踪故正常）。
        [btn sendActionOn:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)];
        [btn addSubview:g_mergedView];
    }
    NSLog(@"[FrsetStats] 合并显示项已创建");
    FSBarLog(@"合并显示项已创建");
}

// 移除合并项（保存位置后销毁）
static void FSBarRemoveMergedItem(void) {
    if (!g_mergedItem) return;
    FSBarPositionSave(@"frset.bar.merged");
    for (NSString *key in [g_views allKeys]) {
        FSBarWidgetView *v = g_views[key];
        if (v.superview == g_mergedView) [v removeFromSuperview];
    }
    [[NSStatusBar systemStatusBar] removeStatusItem:g_mergedItem];
    g_mergedItem = nil;
    g_mergedView = nil;
    NSLog(@"[FrsetStats] 合并显示项已移除");
    FSBarLog(@"合并显示项已移除");
}

// v203：设置里关掉「菜单栏性能部件（STATS）」时立即拆除。
// 旧 FSStatsTickStop 只停采样 timer，合并条状态项会留在菜单栏上显示旧值，
// 用户以为「关了没生效 / 开了没显示」，只能重启 App——这里做完整回收。
void FSBarTeardown(void) {
    g_manager = nil;
    for (NSString *key in [g_ownItems allKeys]) {
        NSStatusItem *it = g_ownItems[key];
        FSBarPositionSave(it.autosaveName);
        [[NSStatusBar systemStatusBar] removeStatusItem:it];
    }
    [g_ownItems removeAllObjects];
    for (NSString *key in [g_views allKeys]) {
        FSBarWidgetView *v = g_views[key];
        [v removeFromSuperview];
    }
    [g_views removeAllObjects];
    FSBarRemoveMergedItem();
    NSLog(@"[FrsetStats] 部件引擎已拆除（合并条/独立项全部移除）");
}

// ============ v17：菜单位置——合并项紧贴 Frset 主图标 ============
// 用户的期望：监测条与主图标相邻，中间不插其他 App 图标。
// 机制：系统按键 "NSStatusItem Preferred Position <autosaveName>" 排序（创建时读取）；
//       候选值是否即时生效由实测决定（FRSET_POSCHK 探针 + 启动自动校准）。

static NSStatusItem *FSBarMainItem(void) {
    // v30：重建版主图标项（外部注入——重建版没有"原生监控项"，主项由 Swift
    // 状态栏自建；不注入的话 FSBarMainItem 永远返回 nil，位置校准与保邻修正
    // 全部静默跳过，合并条与主图标裂开 17-44pt）
    if (g_mainItemRef && g_mainItemRef.button) return g_mainItemRef;
    for (NSStatusItem *it in g_statusItems) {
        NSString *n = it.autosaveName ?: @"";
        if ([n hasPrefix:@"frset."]) continue;
        if (it.button) return it;
    }
    return nil;
}
static NSRect FSBarItemRect(NSStatusItem *it) {
    NSButton *b = it.button;
    if (!b || !b.window) return NSZeroRect;
    return b.window.frame;
}
static BOOL FSBarItemsAdjacent(NSStatusItem *a, NSStatusItem *b, CGFloat tol) {
    NSRect ra = FSBarItemRect(a), rb = FSBarItemRect(b);
    if (ra.size.width < 1 || rb.size.width < 1) return NO;
    if (fabs(NSMaxX(ra) - rb.origin.x) <= tol) return YES;
    if (fabs(NSMaxX(rb) - ra.origin.x) <= tol) return YES;
    return NO;
}
static CGFloat FSBarItemsGap(NSStatusItem *a, NSStatusItem *b) {
    NSRect ra = FSBarItemRect(a), rb = FSBarItemRect(b);
    if (ra.size.width < 1 || rb.size.width < 1) return 1e9;
    return MIN(fabs(NSMaxX(ra) - rb.origin.x), fabs(NSMaxX(rb) - ra.origin.x));
}
void FSBarSetMainItem(NSStatusItem *item) {
    g_mainItemRef = item;
    if (item) FSBarLog(@"主图标项已注册（%@）", item.autosaveName ?: @"?");
}

/// v30 排障：合并条状态项访问器（坐标探针用；引擎未建项时为 nil）
NSStatusItem *FSBarMergedItem(void) {
    return g_mergedItem;
}

static NSWindow *FSBarDebugPanel(void);   // 前向声明（定义在文件后部）

void FSBarDebugPosProbe(void) {
    NSStatusItem *main = FSBarMainItem();
    NSRect rmain = FSBarItemRect(main), rm = FSBarItemRect(g_mergedItem);
    FSBarLog(@"[pos] 主图标(%@) x=%.0f w=%.0f 右缘=%.0f | 合并条 x=%.0f w=%.0f 右缘=%.0f 相邻=%d",
             main.autosaveName ?: @"?", rmain.origin.x, rmain.size.width, NSMaxX(rmain),
             rm.origin.x, rm.size.width, NSMaxX(rm),
             FSBarItemsAdjacent(g_mergedItem, main, 4));
    // 全部状态项清点（x 升序）
    for (NSStatusItem *it in g_statusItems) {
        NSRect r = FSBarItemRect(it);
        if (r.size.width < 1) continue;
        FSBarLog(@"[pos]   项 %@ x=%.0f w=%.0f v=%d", it.autosaveName ?: @"?", r.origin.x, r.size.width, (int)it.visible);
    }
    // ★ 实验1：全新名 merged 副本（196pt）默认落点（等 1.5s 看是否落座）
    {
        NSStatusItem *pi = [[NSStatusBar systemStatusBar] statusItemWithLength:196];
        pi.autosaveName = [NSString stringWithFormat:@"frset.bar.p1-%ld", (long)[[NSDate date] timeIntervalSince1970]];
        if (pi.button) pi.button.image = [NSImage new];
        [NSThread sleepForTimeInterval:1.5];
        NSRect rp = FSBarItemRect(pi);
        FSBarLog(@"[pos] 实验1 新名(196) x=%.0f w=%.0f win=%d gap(主)=%.0f gap(合并)=%.0f",
                 rp.origin.x, rp.size.width, pi.button.window != nil,
                 FSBarItemsGap(pi, main), FSBarItemsGap(pi, g_mergedItem));
        [[NSStatusBar systemStatusBar] removeStatusItem:pi];
    }
    // ★ 实验2：主图标克隆（复制 image/target/action）落点 + 点击可用性
    {
        NSStatusItem *clone = [[NSStatusBar systemStatusBar] statusItemWithLength:main.length];
        clone.autosaveName = [NSString stringWithFormat:@"frset.bar.mc-%ld", (long)[[NSDate date] timeIntervalSince1970]];
        NSButton *mb = main.button, *cb = clone.button;
        if (mb && cb) {
            cb.image = mb.image;
            cb.imagePosition = mb.imagePosition;
            cb.imageScaling = mb.imageScaling;
            cb.target = mb.target;
            cb.action = mb.action;
            cb.toolTip = mb.toolTip;
            [cb sendActionOn:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)];
        }
        [NSThread sleepForTimeInterval:1.5];
        NSRect rc = FSBarItemRect(clone);
        FSBarLog(@"[pos] 实验2 主图标克隆 x=%.0f w=%.0f gap(主)=%.0f gap(合并)=%.0f",
                 rc.origin.x, rc.size.width, FSBarItemsGap(clone, main), FSBarItemsGap(clone, g_mergedItem));
        // 点击测试
        BOOL before = FSBarDebugPanel().isVisible;
        [[NSStatusBar systemStatusBar] removeStatusItem:clone];
        FSBarLog(@"[pos] 实验2 克隆已移除（面板此前 visible=%d，未点击避免干扰）", (int)before);
    }
}

// 隐藏原生 SwiftUI 托管视图（自愈）
static void FSBarHideNativeSubviews(NSButton *btn, NSView *keep) {
    for (NSView *v in [btn.subviews copy]) {
        if (v == keep) continue;
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"Hosting"] || [cn containsString:@"MenuBarMetric"]) {
            if (!v.hidden) v.hidden = YES;
        }
    }
}

// 把一个部件视图挂到状态项上（原生/自建通用；自愈：长度/挂载/z序）
static void FSBarMount(NSStatusItem *item, NSString *module, NSString *form) {
    if (!item || !item.button) return;
    NSString *key = [NSString stringWithFormat:@"%@/%@", module, form];
    FSBarWidgetView *w = g_views[key];
    if (!w) {
        w = [[FSBarWidgetView alloc] initWithModule:module form:form];
        g_views[key] = w;
    }
    NSButton *btn = item.button;
    FSBarHideNativeSubviews(btn, w);
    CGFloat want = [w preferredWidth];
    // v52 备注（用户反馈"默认距离太大"）：实测 macOS 给每个独立状态项窗口固定加
    //   16pt（左右各 8pt）内边距——window = len + 16，相邻窗口紧贴，视觉间隙即双方
    //   各 8pt。试过"缩 len + 视图外扩画进内边距"：NSButton 会裁掉超出 bounds 的
    //   内容（图表右缘被切），不可行。独立模式无法再压缩，收紧只能走合并条
    //   （CombinedModules=YES + spacing 0 + 分隔线关）。
    if (fabs(item.length - want) > 0.5) item.length = want;   // 先定长（按钮随之布局）
    if (w.superview != btn) [btn addSubview:w];
    else if (btn.subviews.lastObject != w) [btn addSubview:w positioned:NSWindowAbove relativeTo:nil];
    NSRect b = btn.bounds;
    if (b.size.width < 1) b.size.width = want;
    if (fabs(w.frame.size.width - b.size.width) > 0.5 || fabs(w.frame.size.height - b.size.height) > 0.5) {
        w.frame = NSMakeRect(0, 0, b.size.width, b.size.height);
    }
}

static void FSBarDumpItems(const char *tag);   // 前向声明
// 设置驱动的状态项重建（v11：合并 / 独立 双模式）
static void FSBarReconcile(void) {
    if (g_tickN == 0) FSBarDumpItems("start");

    if (FSBarMergedEnabled()) {
        // ===== 合并模式（对齐 Stats CombinedModules）：原生项全隐藏，部件紧排在单个合并项内 =====
        for (NSString *m in g_nativeItems) {
            NSStatusItem *it = g_nativeItems[m];
            if (it.visible) it.visible = NO;
        }
        for (NSString *key in [g_ownItems allKeys]) {   // 清理独立自建项
            NSStatusItem *it = g_ownItems[key];
            FSBarPositionSave(it.autosaveName);
            [[NSStatusBar systemStatusBar] removeStatusItem:it];
            [g_ownItems removeObjectForKey:key];
            NSLog(@"[FrsetStats] 合并模式：独立项移除 %@", key);
        }
        NSMutableSet *wanted = [NSMutableSet set];
        for (NSString *m in FSBarOrderedModules(g_cfg)) {
            NSArray *forms = FSBarEnabledForms(m);
            if (!forms.count) continue;
            for (NSString *form in forms) {
                NSString *key = [NSString stringWithFormat:@"%@/%@", m, form];
                [wanted addObject:key];
                if (!g_views[key]) g_views[key] = [[FSBarWidgetView alloc] initWithModule:m form:form];
            }
        }
        for (NSString *key in [g_views allKeys]) {   // 孤儿视图清理
            if (![wanted containsObject:key]) {
                FSBarWidgetView *v = g_views[key];
                [v removeFromSuperview];
                [g_views removeObjectForKey:key];
            }
        }
        FSBarEnsureMergedItem();
        FSBarMergedLayout();
        return;
    }

    // ===== 独立模式（v10 逻辑）：原生项各挂一个部件 + 其余部件自建独立项 =====
    FSBarRemoveMergedItem();
    NSMutableDictionary *desired = [NSMutableDictionary dictionary];   // "module/form" → module
    NSMutableDictionary *nativeFirstForm = [NSMutableDictionary dictionary]; // module → first form
    for (NSString *m in FSBarOrderedModules(g_cfg)) {
        NSArray *forms = FSBarEnabledForms(m);
        NSStatusItem *native = g_nativeItems[m];
        for (NSUInteger i = 0; i < forms.count; i++) {
            NSString *f = forms[i];
            if (i == 0 && native) nativeFirstForm[m] = f;
            else desired[[NSString stringWithFormat:@"%@/%@", m, f]] = m;
        }
        // 原生项可见性：该模块被禁用则隐藏原生图标
        if (native) {
            BOOL wantVisible = forms.count > 0;
            if (native.visible != wantVisible) native.visible = wantVisible;
        }
    }
    NSMutableSet *wantedKeys = [NSMutableSet setWithArray:[desired allKeys]];
    for (NSString *m in nativeFirstForm) {
        [wantedKeys addObject:[NSString stringWithFormat:@"%@/%@", m, nativeFirstForm[m]]];
    }
    // 原生项挂载
    for (NSString *m in nativeFirstForm) {
        FSBarMount(g_nativeItems[m], m, nativeFirstForm[m]);
    }
    // 移除不再需要的自建项
    for (NSString *key in [g_ownItems allKeys]) {
        if (!desired[key]) {
            NSStatusItem *it = g_ownItems[key];
            FSBarPositionSave(it.autosaveName);
            [[NSStatusBar systemStatusBar] removeStatusItem:it];
            [g_ownItems removeObjectForKey:key];
            NSLog(@"[FrsetStats] 自建项移除: %@", key);
        }
    }
    // 清理孤儿视图（模块禁用/形态切换后残留）
    for (NSString *key in [g_views allKeys]) {
        if (![wantedKeys containsObject:key]) {
            FSBarWidgetView *v = g_views[key];
            [v removeFromSuperview];
            [g_views removeObjectForKey:key];
        }
    }
    // 创建/挂载自建项
    for (NSString *key in desired) {
        NSStatusItem *it = g_ownItems[key];
        if (!it) {
            NSString *ident = [@"frset.bar." stringByAppendingString:[key stringByReplacingOccurrencesOfString:@"/" withString:@"."]];
            FSBarPositionRestore(ident);   // 创建前恢复偏好位置（Stats 同款机制）
            it = [[NSStatusBar systemStatusBar] statusItemWithLength:30];
            it.autosaveName = ident;
            g_ownItems[key] = it;
            NSLog(@"[FrsetStats] 自建项创建: %@", key);
            if (it.button) {
                it.button.target = g_manager;
                it.button.action = @selector(openItem:);
                // ★ 同上（对齐 Stats）：自建状态项按钮需"按下即派发"
                [it.button sendActionOn:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)];
            }
        }
        NSArray *parts = [key componentsSeparatedByString:@"/"];
        FSBarMount(it, parts[0], parts[1]);
    }
}

// v19：菜单栏明暗切换后触发全部部件重绘（合并容器 + 各部件视图）
static void FSBarRefreshAllWidgets(void) {
    if (g_mergedView) [g_mergedView setNeedsDisplay:YES];
    for (NSString *key in g_views) {
        NSView *v = g_views[key];
        [v setNeedsDisplay:YES];
    }
}

// 数值刷新（按模块间隔）
static void FSBarRefreshValues(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (NSString *key in g_views) {
        FSBarWidgetView *w = g_views[key];
        if (!w.superview) continue;
        NSTimeInterval iv = FSBarModuleInterval(w.module);
        if (w.lastUpdate == 0 || now - w.lastUpdate >= iv - 0.01) {
            [w refreshWithSnap:&g_snap];
        }
    }
}

void FSBarReloadFromStore(void) {
    FSBarLoadStore();
    g_cfgGen++;   // v126：配置重载 → FSBarEnabledForms 缓存失效
    for (FSBarWidgetView *view in g_views.allValues) {
        view.lastUpdate = 0;
    }
    if (g_manager) FSBarReconcile();
    if (g_manager) FSBarRefreshValues();
    FSBarRefreshAllWidgets();
}

void FSBarResetFromStats(void) {
    g_cfg = [NSMutableDictionary dictionary];
    FSBarImportFromStats(g_cfg);
    if (!g_cfg[@"CPU_widget"] && !g_cfg[@"RAM_widget"] && !g_cfg[@"Network_widget"]) {
        FSBarSeedDefaults(g_cfg);   // Stats 不存在时的兜底
    }
    g_cfgGen++;   // v126：配置重置 → FSBarEnabledForms 缓存失效
    FSBarSaveStore();
    FSBarReconcile();
    NSLog(@"[FrsetStats] 部件设置已从 Stats 重新导入");
}

void FSBarResetToDefaults(void) {
    g_cfg = [NSMutableDictionary dictionary];
    FSBarSeedDefaults(g_cfg);
    g_cfgGen++;   // v126：配置重置 → FSBarEnabledForms 缓存失效
    FSBarSaveStore();
    FSBarReconcile();
    NSLog(@"[FrsetStats] 部件设置已恢复默认");
}

static void FSBarResolveNativeItems(void) {
    for (NSStatusItem *it in g_statusItems) {
        NSString *m = FSBarNativeModule(it.autosaveName);
        if (m) g_nativeItems[m] = it;
    }
}

// 诊断：状态项清单（一次性）
static void FSBarDumpItems(const char *tag) {
    NSMutableString *s = [NSMutableString string];
    for (NSStatusItem *it in g_statusItems) {
        [s appendFormat:@"%@(v=%d) ", it.autosaveName ?: @"<nil>", it.visible];
    }
    NSLog(@"[FrsetStats] 状态项[%s]: %@", tag, s);

    // v51 诊断：独立模式自有项的屏幕坐标/宽度 + 相邻间隙（排查"默认距离太大"）
    if (g_ownItems.count == 0) return;
    NSArray *keys = [[g_ownItems allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *key in keys) {
        NSStatusItem *it = g_ownItems[key];
        NSRect r = FSBarItemRect(it);
        [rows addObject:@{@"key": key, @"x": @(r.origin.x), @"w": @(r.size.width), @"len": @(it.length)}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"x"] compare:b[@"x"]];
    }];
    NSMutableString *d = [NSMutableString string];
    CGFloat prevMax = -1;
    for (NSDictionary *row in rows) {
        CGFloat x = [row[@"x"] doubleValue], w = [row[@"w"] doubleValue];
        CGFloat gap = (prevMax < 0) ? 0 : (x - prevMax);
        [d appendFormat:@"\n  %@ x=%.1f w=%.1f len=%.1f gap=%.1f", row[@"key"], x, w, [row[@"len"] doubleValue], gap];
        prevMax = x + w;
    }
    FSBarLog(@"[items] 自有项[%s]%@", tag, d);
}

void FSBarSystemTick(void) {
    if (!g_cfg) return;
    // 每 0.5s：解析原生项 + 复检结构；数值按模块间隔
    FSBarResolveNativeItems();
    FSBarReconcile();
    FSBarRefreshValues();
    g_tickN++;
    if (g_tickN == 1) FSBarDumpItems("tick1");
    if (g_tickN == 8) FSBarDumpItems("tick8");   // v51：4s 后布局稳定，再采一次间距
}

void FSBarSystemStart(NSMutableArray *statusItems) {
    FSBarLoadStore();
    g_statusItems = statusItems;
    g_ownItems = [NSMutableDictionary dictionary];
    g_views = [NSMutableDictionary dictionary];
    g_nativeItems = [NSMutableDictionary dictionary];
    g_manager = [[FSBarManager alloc] init];
    FSBarResolveNativeItems();   // 必须先解析原生项，否则首轮会把原生模块也建成自建项（重复图标）
    const char *catOverride = getenv("FRSET_MAINICON_CAT");
    if ((catOverride && *catOverride) || FSBarAsBool(FSBarCfgRaw(@"Bar", nil, @"MainIconCat"), NO)) {
        FSRunCatStartTimer();
    }
    NSLog(@"[FrsetStats] 原生项解析: %lu 个", (unsigned long)g_nativeItems.count);
    FSBarReconcile();
    NSLog(@"[FrsetStats] 部件系统启动（%lu 个模块已配置）", (unsigned long)FSBarAllModules().count);
    FSBarLog(@"部件系统启动 merged=%d spacing=%@ sep=%d screen=%ld",
             FSBarMergedEnabled(), FSBarGlobalStr(@"CombinedModules_spacing", @"none"),
             FSBarMergedSeparator(), (long)0);
    // v28：合并条探针（FRSET_BARCHAR=1）—— 打印位置/可见性并渲染内容快照
    if (getenv("FRSET_BARCHAR") && *getenv("FRSET_BARCHAR")) FSBarDebugCharProbe();
}


// ============ v14b：点击链路对照实验（FRSET_CLICKCHK=1 时由注入层触发一次；生产不触发） ============
BOOL FSBarDebugMergedReady(void) { return g_mergedItem != nil && g_mergedView != nil; }

static NSWindow *FSBarDebugPanel(void) {
    for (NSWindow *w in [NSApp windows]) {
        if ([NSStringFromClass(w.class) isEqualToString:@"Frset.FloatingPanel"]) return w;
    }
    return nil;
}

static NSStatusItem *FSBarDebugMainItem(void) {
    for (NSStatusItem *it in g_statusItems) {
        NSString *n = it.autosaveName ?: @"";
        if (![n hasPrefix:@"frset."] && it.button) return it;
    }
    return nil;
}

static NSPoint FSBarDebugCGPointForButton(NSButton *btn) {
    NSPoint winPt = [btn convertPoint:NSMakePoint(btn.bounds.size.width * 0.5, NSMidY(btn.bounds)) toView:nil];
    NSPoint scr = [btn.window convertPointToScreen:winPt];
    CGFloat fh = NSMaxY([NSScreen screens].firstObject.frame);
    return NSMakePoint(scr.x, fh - scr.y);
}

static void FSBarDebugSyntheticClickAtCG(NSPoint cg) {
    CGWarpMouseCursorPosition(cg);
    [NSThread sleepForTimeInterval:0.05];
    CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, cg, kCGMouseButtonLeft);
    CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, cg, kCGMouseButtonLeft);
    if (d) CGEventPost(kCGHIDEventTap, d);
    [NSThread sleepForTimeInterval:0.08];
    if (u) CGEventPost(kCGHIDEventTap, u);
    if (d) CFRelease(d);
    if (u) CFRelease(u);
}

// 向本进程直投鼠标事件（尝试绕开 HID tap 投递限制）
static void FSBarDebugPostToPidClick(NSPoint cg) {
    CGWarpMouseCursorPosition(cg);
    [NSThread sleepForTimeInterval:0.05];
    CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, cg, kCGMouseButtonLeft);
    CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, cg, kCGMouseButtonLeft);
    pid_t pid = [NSProcessInfo processInfo].processIdentifier;
    if (d) CGEventPostToPid(pid, d);
    [NSThread sleepForTimeInterval:0.08];
    if (u) CGEventPostToPid(pid, u);
    if (d) CFRelease(d);
    if (u) CFRelease(u);
}

// 应用内事件直投（postEvent；不经过系统投递链，验证 命中→按钮→动作）
static void FSBarDebugPostInAppClick(NSButton *btn) {
    NSWindow *w = btn.window;
    if (!w) return;
    NSPoint winPt = [btn convertPoint:NSMakePoint(NSMidX(btn.bounds), NSMidY(btn.bounds)) toView:nil];
    NSTimeInterval ts = [NSProcessInfo processInfo].systemUptime;
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                       location:winPt modifierFlags:0 timestamp:ts
                                   windowNumber:w.windowNumber context:nil
                                     eventNumber:9001 clickCount:1 pressure:1.0];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                     location:winPt modifierFlags:0 timestamp:ts + 0.05
                                 windowNumber:w.windowNumber context:nil
                                   eventNumber:9002 clickCount:1 pressure:0.0];
    [NSApp postEvent:up atStart:NO];
    [NSApp postEvent:down atStart:YES];
}

// 指定 tap 的合成点击（session 级；尝试走系统路由）
static void FSBarDebugPostTapClick(NSButton *btn, CGEventTapLocation tap) {
    NSPoint cg = FSBarDebugCGPointForButton(btn);
    CGWarpMouseCursorPosition(cg);
    [NSThread sleepForTimeInterval:0.05];
    CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, cg, kCGMouseButtonLeft);
    CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, cg, kCGMouseButtonLeft);
    if (d) CGEventPost(tap, d);
    [NSThread sleepForTimeInterval:0.08];
    if (u) CGEventPost(tap, u);
    if (d) CFRelease(d);
    if (u) CFRelease(u);
}

void FSBarDebugClosePanelIfNeeded(void) {
    if (FSBarDebugPanel().isVisible) {
        NSStatusItem *mi = FSBarDebugMainItem();
        if (mi.button) [mi.button performClick:nil];
    }
}

void FSBarDebugClickProbe(void) {
    NSPoint c0 = [NSEvent mouseLocation];
    NSButton *btn = g_mergedItem.button;

    // 本地事件监视：证实"鼠标事件是否投递到本进程"
    id mon = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
                                                  handler:^NSEvent *(NSEvent *e) {
        FSBarLog(@"CLICKCHK[monitor] %@ win=%@ loc=(%.0f,%.0f)",
                 e.type == NSEventTypeLeftMouseDown ? @"down" : @"up",
                 NSStringFromClass([e.window class]), e.locationInWindow.x, e.locationInWindow.y);
        return e;
    }];

    FSBarLog(@"CLICKCHK 开始: btn.frame=%@ enabled=%d win=%@ winFrame=%@ level=%.0f ignores=%d",
             NSStringFromRect(btn.frame), btn.enabled, NSStringFromClass([btn.window class]),
             NSStringFromRect(btn.window.frame), btn.window.level, btn.window.ignoresMouseEvents);
    NSMutableString *names = [NSMutableString string];
    for (NSStatusItem *it in g_statusItems)
        [names appendFormat:@"%@(v=%d,tip=%@) ", it.autosaveName ?: @"<nil>", it.visible, it.button.toolTip ?: @"-"];
    FSBarLog(@"CLICKCHK 状态项: %@", names);
    FSBarLog(@"CLICKCHK 面板初始 visible=%d", FSBarDebugPanel().isVisible);

    FSBarDebugClosePanelIfNeeded();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FSBarLog(@"CLICKCHK: T0 后面板visible=%d", FSBarDebugPanel().isVisible);

        // T3：对照组——合成点击主图标（原生按钮、历史验证可靠）
        NSStatusItem *mi = FSBarDebugMainItem();
        if (mi.button) {
            FSBarDebugSyntheticClickAtCG(FSBarDebugCGPointForButton(mi.button));
            FSBarLog(@"CLICKCHK: T3 已合成点击主图标");
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FSBarLog(@"CLICKCHK: T3(主图标·合成点击)后 面板visible=%d", FSBarDebugPanel().isVisible);
            FSBarDebugClosePanelIfNeeded();

            // T1：合并项——瞬移+立刻点击（无悬停，tooltip 来不及出现）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FSBarDebugSyntheticClickAtCG(FSBarDebugCGPointForButton(btn));
                FSBarLog(@"CLICKCHK: T1 已合成点击合并项（瞬移即刻）");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    FSBarLog(@"CLICKCHK: T1(合并项·瞬移点击)后 面板visible=%d", FSBarDebugPanel().isVisible);
                    FSBarDebugClosePanelIfNeeded();

                    // T2a：合并项——悬停 2.6s（tooltip 出现）后点击
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        CGWarpMouseCursorPosition(FSBarDebugCGPointForButton(btn));
                        [NSThread sleepForTimeInterval:2.6];
                        FSBarDebugSyntheticClickAtCG(FSBarDebugCGPointForButton(btn));
                        FSBarLog(@"CLICKCHK: T2a 已合成点击合并项（悬停2.6s后）");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            FSBarLog(@"CLICKCHK: T2a(合并项·悬停后点击)后 面板visible=%d", FSBarDebugPanel().isVisible);
                            FSBarDebugClosePanelIfNeeded();

                            // T2b：去掉 tooltip + 悬停 2.6s 后点击
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                NSString *savedTip = btn.toolTip;
                                btn.toolTip = nil;
                                CGWarpMouseCursorPosition(FSBarDebugCGPointForButton(btn));
                                [NSThread sleepForTimeInterval:2.6];
                                FSBarDebugSyntheticClickAtCG(FSBarDebugCGPointForButton(btn));
                                FSBarLog(@"CLICKCHK: T2b 已合成点击合并项（无提示+悬停2.6s后）");
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    FSBarLog(@"CLICKCHK: T2b(无提示·悬停后点击)后 面板visible=%d", FSBarDebugPanel().isVisible);
                                    btn.toolTip = savedTip;
                                    // T4：PostToPid 自投递（验证"投递→命中→按钮跟踪→动作"全链）
                                    FSBarDebugClosePanelIfNeeded();
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                        FSBarDebugPostToPidClick(FSBarDebugCGPointForButton(btn));
                                        FSBarLog(@"CLICKCHK: T4 已向本进程投递鼠标事件（PostToPid）");
                                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                            FSBarLog(@"CLICKCHK: T4(合并项·PostToPid)后 面板visible=%d", FSBarDebugPanel().isVisible);
                                            // T5：掩码 A/B——验证"按下即派发"（sendActionOn）是否为点击失效根因
                                            FSBarDebugClosePanelIfNeeded();
                                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                NSUInteger prev = [btn sendActionOn:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)];
                                                FSBarLog(@"CLICKCHK: 按钮派发掩码读回=0x%lx（0xA=按下派发已生效）", (unsigned long)prev);
                                                [btn sendActionOn:NSEventMaskLeftMouseUp];   // A：模拟旧默认（抬起派发）
                                                FSBarDebugPostInAppClick(btn);
                                                FSBarLog(@"CLICKCHK: T5a 已投递（掩码=mouseUp 模拟旧行为）");
                                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                    FSBarLog(@"CLICKCHK: T5a(mouseUp掩码)后 面板visible=%d", FSBarDebugPanel().isVisible);
                                                    FSBarDebugClosePanelIfNeeded();
                                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                        [btn sendActionOn:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)];
                                                        FSBarDebugPostInAppClick(btn);
                                                        FSBarLog(@"CLICKCHK: T5b 已投递（掩码=mouseDown 新行为）");
                                                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                            FSBarLog(@"CLICKCHK: T5b(mouseDown掩码)后 面板visible=%d module=%d", FSBarDebugPanel().isVisible, FSBarDebugCurrentModule());
                                                            // T6：session-tap 投递（走系统路由的最后尝试）
                                                            FSBarDebugClosePanelIfNeeded();
                                                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                FSBarDebugPostTapClick(btn, kCGSessionEventTap);
                                                                FSBarLog(@"CLICKCHK: T6a 已投递（kCGSessionEventTap, 掩码=mouseDown）");
                                                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                    FSBarLog(@"CLICKCHK: T6a 后 面板visible=%d", FSBarDebugPanel().isVisible);
                                                                    FSBarDebugClosePanelIfNeeded();
                                                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                        FSBarDebugPostTapClick(btn, kCGAnnotatedSessionEventTap);
                                                                        FSBarLog(@"CLICKCHK: T6b 已投递（kCGAnnotatedSessionEventTap）");
                                                                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                            FSBarLog(@"CLICKCHK: T6b 后 面板visible=%d", FSBarDebugPanel().isVisible);
                                                                            [NSEvent removeMonitor:mon];
                                                                            CGFloat fh = NSMaxY([NSScreen screens].firstObject.frame);
                                                                            CGWarpMouseCursorPosition(NSMakePoint(c0.x, fh - c0.y));
                                                                            FSBarLog(@"CLICKCHK 完成");
                                                                        });
                                                                    });
                                                                });
                                                            });
                                                        });
                                                    });
                                                });
                                            });
                                        });
                                    });
                                });
                            });
                        });
                    });
                });
            });
        });
    });
}

// ============ v15：设置界面支持（模块图标 / 部件预览渲染） ============

// 模块图标（对齐 Stats ModuleConfig.icon 的符号选择）
NSString *FSBarModuleSymbol(NSString *module) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"CPU": @"cpu", @"RAM": @"memorychip", @"GPU": @"cube.transparent",
                @"Disk": @"internaldrive", @"Network": @"network",
                @"Sensors": @"thermometer", @"Battery": @"battery.100",
                @"Power": @"bolt.fill", @"CPUPower": @"cpu", @"GPUPower": @"display"};
    });
    return map[module] ?: @"gear";
}

// 预览用示例快照（覆盖各模块代表值）
static FSSnap FSBarPreviewSnap(int tick) {
    FSSnap s; memset(&s, 0, sizeof(s));
    s.valid = 1;
    double wob = 0.06 * sin(tick * 0.9);
    s.cpuUsage = 0.38 + wob; s.cpuSystem = 0.12; s.cpuUser = 0.26; s.cpuIdle = 1 - s.cpuUsage;
    s.coreCount = 10;
    for (int i = 0; i < 10; i++) s.coreUsage[i] = 0.2 + 0.5 * fabs(sin(i * 1.7 + tick * 0.5));
    s.ramRatio = 0.62; s.ramAppRatio = 0.5; s.ramCompRatio = 0.12; s.ramWireRatio = 0.38;
    s.ramUsedBytes = 17.0 * 1073741824.0; s.ramTotalBytes = 27.4 * 1073741824.0;
    s.diskUsedRatio = 0.75;
    s.diskTotalBytes = 1000.2e9; s.diskFreeBytes = 250e9;
    s.diskReadBps = (18.0 + 10 * fabs(sin(tick * 0.6))) * 1048576.0;
    s.diskWriteBps = (7.0 + 6 * fabs(sin(tick * 0.4 + 1))) * 1048576.0;
    s.netDownBps = (4.2 + 3.5 * fabs(sin(tick * 0.7 + 2))) * 1048576.0;
    s.netUpBps = (0.6 + 0.5 * fabs(sin(tick * 0.5))) * 1048576.0;
    s.batteryPresent = 1; s.batteryCharging = 0; s.batteryPercent = 75; s.batteryRemainMin = 312;
    s.gpuTemp = 45; s.sensorValue = 38.5; strcpy(s.sensorKey, "PPBR");
    s.load1 = 3.2; s.load5 = 2.8; s.load15 = 2.4;
    s.power = (frset_power_t){24.6 + wob * 10, 36, 8.4 + wob * 5, 4.2 + wob * 3, 0.4, 1.2, 0.6, 16.8 + wob * 8};
    return s;
}

void FSBarUpdateConfiguredPreview(NSView *container, NSArray<NSString *> *modules, NSDictionary *configuration, BOOL dark) {
    [container setFrameSize:NSMakeSize(container.frame.size.width, 22)];
    container.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    NSMutableDictionary *existing = [NSMutableDictionary dictionary];
    for (NSView *view in container.subviews) {
        if ([view isKindOfClass:FSBarWidgetView.class]) {
            FSBarWidgetView *widget = (FSBarWidgetView *)view;
            existing[[NSString stringWithFormat:@"%@/%@", widget.module, widget.form]] = widget;
        }
    }
    NSMutableArray *widgets = [NSMutableArray array];
    for (NSString *module in modules) {
        for (NSString *form in FSBarConfiguredForms(module, configuration)) {
            FSBarWidgetView *widget = existing[[NSString stringWithFormat:@"%@/%@", module, form]];
            if (!widget) {
                widget = [[FSBarWidgetView alloc] initWithModule:module form:form];
                widget.configuration = configuration;
                BOOL chart = [form isEqualToString:@"line_chart"] || [form isEqualToString:@"network_chart"];
                for (int i = chart ? 0 : 119; i < 120; i++) {
                    FSSnap snap = FSBarPreviewSnap(i);
                    [widget refreshWithSnap:&snap];
                }
            } else {
                widget.configuration = configuration;
                widget.needsDisplay = YES;
            }
            [widgets addObject:widget];
        }
    }
    for (FSBarWidgetView *widget in existing.allValues)
        if (![widgets containsObject:widget]) [widget removeFromSuperview];
    BOOL merged = FSBarAsBool(configuration[@"CombinedModules"], NO);
    FSBarLayoutWidgets(container, widgets, merged ? FSBarConfigurationSpacing(configuration) : 16,
                       merged && FSBarAsBool(configuration[@"CombinedModules_separator"], YES),
                       configuration[@"CombinedModules_separatorColor"] ?: @"monochrome");
}

NSView *FSBarCreateConfiguredPreview(NSArray<NSString *> *modules, NSDictionary *configuration, BOOL dark) {
    NSView *container = [[FSBarMergedView alloc] initWithFrame:NSMakeRect(0, 0, 1, 22)];
    FSBarUpdateConfiguredPreview(container, modules, configuration, dark);
    return container;
}

NSView *FSRunCatCreatePreview(BOOL dark) {
    FSRunCatIconView *view = [[FSRunCatIconView alloc] initWithFrame:NSMakeRect(0, 0, 34, 22)];
    view.fixedFrame = @3; // 非空标记预览；挂载可见后由实例定时器轮播。
    view.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    return view;
}

NSImage *FSBarRenderFormPreview(NSString *module, NSString *form, BOOL dark) {
    NSMutableDictionary *cfg = [FSBarConfigurationSnapshot() mutableCopy];
    cfg[[module stringByAppendingString:@"_widget"]] = form;
    NSView *view = FSBarCreateConfiguredPreview(@[module], cfg, dark);
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSImage *image = [[NSImage alloc] initWithSize:view.bounds.size];
    [image addRepresentation:rep];
    return image;
}

// ============ v18：反相信号探针（FRSET_APPEARCHK=1） ============
// 打印各层级 appearance，验证 FSBarDark 的判定源：
//   · mergedItem.button.effectiveAppearance —— 状态栏按钮（应随菜单栏明暗在
//     VibrantLight/VibrantDark 间切换；Tahoe 按壁纸反相时同样体现）
//   · mergedView / widget views —— 绘制上下文
//   · NSApp.effectiveAppearance —— App 级（旧实现仅用此源，感知不到菜单栏反相）
void FSBarDebugAppearanceProbe(void) {
    FSBarLog(@"[appear] NSApp.effectiveAppearance = %@", NSApp.effectiveAppearance.name);
    if (g_mergedItem.button) {
        FSBarLog(@"[appear] mergedItem.button.effectiveAppearance = %@",
                 g_mergedItem.button.effectiveAppearance.name);
    }
    if (g_mergedView) {
        FSBarLog(@"[appear] mergedView.effectiveAppearance = %@ dark=%d",
                 g_mergedView.effectiveAppearance.name, (int)FSBarDark(g_mergedView));
    }
    for (NSString *key in g_views) {
        NSView *v = g_views[key];
        FSBarLog(@"[appear] widget[%@].effectiveAppearance = %@ dark=%d",
                 key, v.effectiveAppearance.name, (int)FSBarDark(v));
    }
    for (NSStatusItem *it in g_statusItems) {
        if (it.button) {
            FSBarLog(@"[appear] item[%@].button.effectiveAppearance = %@",
                     it.autosaveName ?: @"?", it.button.effectiveAppearance.name);
        }
    }
}

// ============ v28：合并条探针（FRSET_BARCHAR=1） ============
// 诊断三件事（用户反馈"看不到监测条"排查用）：
//   ① 合并项按钮/容器的 window frame 与可见性（屏幕坐标 rect）
//   ② 每个部件的 frame 与父视图
//   ③ 把合并容器渲染成 PNG（/tmp/frset_merged_bar.png）——直接看内容画对了没
void FSBarDebugCharProbe(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FSBarLog(@"[barchar] mergedItem=%@ mergedView=%@",
                 g_mergedItem ? @"有" : @"无", g_mergedView ? @"有" : @"无");
        if (g_mergedItem && g_mergedItem.button) {
            NSButton *b = g_mergedItem.button;
            NSWindow *w = b.window;
            FSBarLog(@"[barchar] button=%@ frame=%@ hidden=%d alpha=%.2f length=%.0f",
                     NSStringFromRect(b.frame), NSStringFromRect(b.frame), (int)b.hidden, b.alphaValue,
                     g_mergedItem.length);
            FSBarLog(@"[barchar] button.window=%@ winFrame=%@ visible=%d level=%.0f alpha=%.2f",
                     w ? NSStringFromClass([w class]) : @"nil",
                     w ? NSStringFromRect(w.frame) : @"-",
                     w ? (int)w.isVisible : -1, w ? (double)w.level : -1, w ? w.alphaValue : -1);
            if (w) {
                NSRect bInWin = [b convertRect:b.bounds toView:nil];
                NSRect scr = [w convertRectToScreen:bInWin];
                FSBarLog(@"[barchar] button 屏幕矩形(NS坐标)=%@ 屏幕高=%.0f",
                         NSStringFromRect(scr), NSMaxY([NSScreen screens].firstObject.frame));
            }
        }
        if (g_mergedView) {
            FSBarLog(@"[barchar] mergedView frame=%@ hidden=%d window=%@",
                     NSStringFromRect(g_mergedView.frame), (int)g_mergedView.hidden,
                     g_mergedView.window ? NSStringFromClass([g_mergedView.window class]) : @"nil");
        }
        for (NSString *key in g_views) {
            FSBarWidgetView *v = g_views[key];
            FSBarLog(@"[barchar] widget[%@] frame=%@ super=%@ hidden=%d", key,
                     NSStringFromRect(v.frame),
                     v.superview ? NSStringFromClass([v.superview class]) : @"nil", (int)v.hidden);
        }
        FSBarLog(@"[barchar] mouseLocation(NS坐标)=%@", NSStringFromPoint([NSEvent mouseLocation]));

        // 渲染合并条内容快照
        if (g_mergedView && g_mergedView.frame.size.width > 2) {
            NSView *v = g_mergedView;
            [v setNeedsDisplay:YES];
            [v displayIfNeeded];
            NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
            [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:@"/tmp/frset_merged_bar.png" atomically:YES];
            FSBarLog(@"[barchar] 合并条快照 → /tmp/frset_merged_bar.png（%.0fx%.0f pt）",
                     v.bounds.size.width, v.bounds.size.height);
        }
    });
}

