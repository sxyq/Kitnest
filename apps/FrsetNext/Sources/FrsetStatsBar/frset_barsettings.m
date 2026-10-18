// frset_barsettings.m — 设置窗口（v15：Stats 设置界面 1:1 复刻）
// ============================================================================
// 复刻对象（对照 stats-source 逐行）：
//   · SettingsWindow（Stats/Views/Settings.swift）：720×480 分栏窗口、180pt 侧边栏、
//     透明标题栏、工具栏模块开关、frame autosave、最小高 438
//   · SidebarView / MenuItem：32pt 菜单行（18pt 图标 @x=8、13pt 标题 @x=34、圆角 5、
//     选中 selectedContentBackgroundColor + 白字）、底部 45pt 工具按钮行
//   · Window / WidgetSelectorView / WidgetPreview / WidgetSettings（Kit/module/window.swift）：
//     模块页 = 部件选择条（44pt 高、白底小卡、彩色=启用/灰度=停用、点击切换、拖拽排序）
//     + [模块|小组件] 分段控件 + 选项卡；小组件页 = 逐部件设置块（居中标题 + 白底图标座）
//   · PreferencesSection / PreferencesRow / 控件工厂（Kit/helpers.swift, extensions.swift）：
//     圆角 10 分组、1pt 分隔线、行内 12pt 标题 + 右侧控件（mini 开关 / 下拉 / 颜色选择器）
// 文案：全部取自 Stats 官方 zh-Hans 本地化文件（逐字一致）。
// 键名：与 eu.exelban.Stats 完全一致（M_widget / M_<form>_<option> / 全局键）。
// ============================================================================
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>   // CATransaction：禁 NSSwitch 初值隐式动画
#import "frset_barwidgets.h"

// ---------- 动作：block 关联 ----------
typedef void (^FSAct)(id sender);

@interface FSActionHub : NSObject
+ (instancetype)shared;
- (void)handle:(id)sender;
@end
@implementation FSActionHub
+ (instancetype)shared { static FSActionHub *i; static dispatch_once_t o; dispatch_once(&o, ^{ i = [FSActionHub new]; }); return i; }
- (void)handle:(id)sender {
    FSAct b = objc_getAssociatedObject(sender, @selector(handle:));
    if (b) b(sender);
}
@end
static void FSSetAction(NSControl *c, FSAct block) {
    objc_setAssociatedObject(c, @selector(handle:), [block copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    c.target = [FSActionHub shared];
    c.action = @selector(handle:);
}

// ---------- 本地化（Stats 官方 zh-Hans 逐字） ----------
static NSString *FSL(NSString *en) {
    static NSDictionary *d = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        d = @{
            @"Settings": @"设置", @"Dashboard": @"仪表盘", @"Module": @"模块", @"Widgets": @"小组件",
            @"CPU": @"CPU", @"RAM": @"内存", @"GPU": @"GPU", @"Disk": @"磁盘", @"Network": @"网络",
            @"Sensors": @"传感器", @"Battery": @"电池",
            // 部件名（widget_t.name() 官方译文）
            @"Mini widget": @"迷你", @"Line chart widget": @"折线图", @"Bar chart widget": @"柱状图",
            @"Pie chart widget": @"饼图", @"Network chart widget": @"流量图", @"Speed widget": @"速度",
            @"Battery widget": @"电池", @"Memory widget": @"容量", @"Label widget": @"标签",
            @"Tachometer widget": @"转速计", @"State widget": @"状态", @"Icon widget": @"图标",
            // 行/分组
            @"Label": @"标签", @"Value": @"数值", @"Box": @"底盒", @"Frame": @"外框", @"Color": @"颜色",
            @"Colorize value": @"数值颜色", @"Number of reads in the chart": @"图表显示的读取次数",
            @"Scaling": @"缩放", @"Alignment": @"对齐", @"Reverse order": @"调转顺序",
            @"Color of download": @"下载颜色", @"Color of upload": @"上传颜色",
            @"Display mode": @"显示模式", @"Pictogram": @"标识", @"Colorize": @"彩色",
            @"Monochrome accent": @"黑白", @"Show symbols": @"显示标识", @"Units": @"单位",
            @"Additional information": @"附加信息", @"Update interval": @"更新间隔",
            @"Sensor": @"传感器",
            // 选项
            @"None": @"无", @"Square": @"平方", @"Cube": @"立方", @"Logarithmic": @"对数",
            @"Left alignment": @"左对齐", @"Center alignment": @"居中", @"Right alignment": @"右对齐",
            @"One row": @"单行", @"Two rows": @"双行", @"Automatic": @"自动",
            @"Dots": @"点", @"Arrows": @"箭头", @"Characters": @"字母",
            @"Default color": @"默认", @"Transparent when no activity": @"无活动时保持透明",
            @"Constant color": @"恒定颜色",
            @"Percentage": @"百分比", @"Time": @"时间", @"Percentage and time": @"百分比和时间",
            @"Time and percentage": @"时间和百分比",
            // 合并模块页
            @"Combined modules": @"合并模块", @"Spacing": @"间距", @"Separator": @"分隔符",
            @"Show icon instead of widgets": @"显示图标而非小组件", @"Combined details": @"合并详情",
            // 设置分组
            @"Import settings": @"导入设置", @"Reset settings": @"初始化所有设置",
            @"Save": @"保存", @"Choose file": @"选择文件", @"Reset": @"重置",
            // 颜色名（官方）
            @"Custom...": @"自定义...", @"System accent": @"系统强调色",
            @"Based on utilization": @"基于利用率", @"Based on pressure": @"基于压力",
            @"Based on cluster": @"基于集群",
            @"Clear": @"透明", @"White": @"白色", @"Black": @"黑色", @"Gray": @"灰色 1",
            @"Second gray": @"灰色 2", @"Dark gray": @"深灰色", @"Light gray": @"浅灰色",
            @"Red": @"红色 1", @"Second red": @"红色 2", @"Green": @"绿色 1", @"Second green": @"绿色 2",
            @"Blue": @"蓝色 1", @"Second blue": @"蓝色 2", @"Yellow": @"黄色 1", @"Second yellow": @"黄色 2",
            @"Orange": @"橙色 1", @"Second orange": @"橙色 2", @"Purple": @"紫色 1", @"Second purple": @"紫色 2",
            @"Brown": @"棕色 1", @"Second brown": @"棕色 2", @"Cyan": @"青色", @"Magenta": @"洋红色",
            @"Pink": @"粉色", @"Teal": @"蓝绿色", @"Indigo": @"靛蓝色",
            // 空态/提示
            @"No available widgets to configure": @"没有可配置的小组件",
            @"Open application settings": @"打开应用设置", @"Close application": @"关闭应用",
            @"Toggle the module": @"切换模块显示", @"Version": @"版本",
            @"Reimport from Stats": @"重新导入 Stats 配置",
        };
    });
    NSString *v = d[en];
    return v ?: en;
}

// 部件显示名（官方 widget_t.name() 译文；按形态键）
static NSString *FSFormDisplayName(NSString *form) {
    static NSDictionary *m = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        m = @{@"mini": @"Mini widget", @"line_chart": @"Line chart widget", @"bar_chart": @"Bar chart widget",
              @"pie_chart": @"Pie chart widget", @"network_chart": @"Network chart widget", @"speed": @"Speed widget",
              @"memory": @"Memory widget", @"tachometer": @"Tachometer widget", @"battery": @"Battery widget",
              @"label": @"Label widget", @"state": @"State widget", @"icon": @"Icon widget"};
    });
    return FSL(m[form] ?: form);
}

// flipped 文档视图（对齐 Stats FlippedStackView：文档翻转 = 内容顶对齐的正确做法）
@interface FSFlipStack : NSStackView @end
@implementation FSFlipStack
- (BOOL)isFlipped { return YES; }
@end

// ---------- 基础控件 ----------
static NSTextField *FSText(NSString *s, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [[NSTextField alloc] initWithFrame:NSZeroRect];
    t.editable = NO; t.selectable = NO; t.bezeled = NO; t.drawsBackground = NO;
    t.bordered = NO; t.focusRingType = NSFocusRingTypeNone;
    t.stringValue = s ?: @"";
    t.font = [NSFont systemFontOfSize:size weight:w];
    t.textColor = c ?: [NSColor labelColor];
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    t.maximumNumberOfLines = 1;
    t.cell.usesSingleLineMode = YES;
    return t;
}

static NSSwitch *FSNewSwitch(BOOL on, FSAct cb) {
    NSSwitch *sw = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    sw.controlSize = NSControlSizeMini;
    [sw.heightAnchor constraintEqualToConstant:25].active = YES;
    // 程序化设初值禁掉隐式动画：NSSwitch 改 state 默认带动画，首帧会停在关位
    // （缓存截图/刚打开的窗口看到“开着却显示关”）；交互时的动画由用户点击自然触发
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    sw.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    [CATransaction commit];
    FSSetAction(sw, cb);
    return sw;
}

// items：数组，元素为 @[key, 显示名] 或 @[@"separator", @""]
static NSPopUpButton *FSNewSelect(NSArray<NSArray *> *items, NSString *selectedKey, void (^cb)(NSString *key)) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 4, 50, 28) pullsDown:NO];
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSArray *it in items) {
        if ([it[0] isEqualToString:@"separator"]) { [menu addItem:[NSMenuItem separatorItem]]; continue; }
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:FSL(it[1]) action:nil keyEquivalent:@""];
        mi.representedObject = it[0];
        if (selectedKey && [selectedKey isEqualToString:it[0]]) mi.state = NSControlStateValueOn;
        [menu addItem:mi];
    }
    p.menu = menu;
    if (cb) {
        FSSetAction(p, ^(id s) {
            NSMenuItem *mi = [(NSPopUpButton *)s selectedItem];
            if ([mi.representedObject isKindOfClass:[NSString class]]) cb(mi.representedObject);
        });
    }
    [p sizeToFit];
    return p;
}

static NSButton *FSNewButton(NSString *title, FSAct cb) {
    NSButton *b = [NSButton buttonWithTitle:FSL(title) target:nil action:nil];
    b.bezelStyle = NSBezelStyleRounded;
    FSSetAction(b, cb);
    return b;
}

// ---------- 颜色选择器（Stats SColorSelectView 复刻：下拉 + 色块 + 自定义） ----------
static NSString *FSColorHex(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: [NSColor controlAccentColor];
    return [NSString stringWithFormat:@"%02X%02X%02X%02X",
            (unsigned)(s.redComponent * 255), (unsigned)(s.greenComponent * 255),
            (unsigned)(s.blueComponent * 255), (unsigned)(s.alphaComponent * 255)];
}
static NSColor *FSColorResolve(NSString *key) {
    if ([key hasPrefix:@"custom:"]) {
        NSString *hex = [key substringFromIndex:7];
        unsigned long long v = 0;
        if (hex.length >= 6 && [[NSScanner scannerWithString:hex] scanHexLongLong:&v]) {
            unsigned r = (unsigned)((v >> 16) & 0xff), g = (unsigned)((v >> 8) & 0xff), b = (unsigned)(v & 0xff);
            unsigned a = hex.length >= 8 ? (unsigned)((v >> 24) & 0xff) : 255;
            return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
        }
    }
    if ([key isEqualToString:@"white"]) return [NSColor whiteColor];
    if ([key isEqualToString:@"monochrome"]) return [NSColor textColor];
    if ([key isEqualToString:@"systemAccent"] || [key isEqualToString:@"system"]) return [NSColor controlAccentColor];
    return [NSColor controlAccentColor];
}

// 全量颜色条目（对齐 Stats SColor.allColors + Utilization/Pressure/Cluster）
static NSArray<NSArray *> *FSColorItems(void) {
    return @[@[@"utilization", @"Based on utilization"], @[@"pressure", @"Based on pressure"],
             @[@"separator", @""],
             @[@"system", @"System accent"], @[@"monochrome", @"Monochrome accent"],
             @[@"separator", @""],
             @[@"clear", @"Clear"], @[@"white", @"White"], @[@"black", @"Black"],
             @[@"gray", @"Gray"], @[@"secondGray", @"Second gray"], @[@"darkGray", @"Dark gray"], @[@"lightGray", @"Light gray"],
             @[@"red", @"Red"], @[@"secondRed", @"Second red"], @[@"green", @"Green"], @[@"secondGreen", @"Second green"],
             @[@"blue", @"Blue"], @[@"secondBlue", @"Second blue"], @[@"yellow", @"Yellow"], @[@"secondYellow", @"Second yellow"],
             @[@"orange", @"Orange"], @[@"secondOrange", @"Second orange"], @[@"purple", @"Purple"], @[@"secondPurple", @"Second purple"],
             @[@"brown", @"Brown"], @[@"secondBrown", @"Second brown"], @[@"cyan", @"Cyan"], @[@"magenta", @"Magenta"],
             @[@"pink", @"Pink"], @[@"teal", @"Teal"], @[@"indigo", @"Indigo"],
             @[@"separator", @""],
             @[@"custom", @"Custom..."]];
}

@interface FSColorPicker : NSStackView
+ (instancetype)picker:(NSString *)selectedKey cb:(void (^)(NSString *key))cb;
@end
@implementation FSColorPicker {
    NSPopUpButton *_pop;
    NSColorWell *_well;
    NSString *_key;
    void (^_cb)(NSString *);
}
+ (instancetype)picker:(NSString *)selectedKey cb:(void (^)(NSString *))cb {
    return [[self alloc] initWithKey:selectedKey cb:cb];
}
- (instancetype)initWithKey:(NSString *)key cb:(void (^)(NSString *))cb {
    self = [super initWithFrame:NSZeroRect];
    _cb = [cb copy];
    _key = [key isEqualToString:@"systemAccent"] ? @"system" : key;
    self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.alignment = NSLayoutAttributeCenterY;
    self.spacing = 6;
    __weak FSColorPicker *weakSelf = self;
    _pop = FSNewSelect(FSColorItems(), _key, ^(NSString *k) { [weakSelf picked:k]; });
    _well = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 28, 24)];
    _well.color = FSColorResolve(_key);
    [_well.widthAnchor constraintEqualToConstant:28].active = YES;
    [_well.heightAnchor constraintEqualToConstant:24].active = YES;
    _well.target = self;
    _well.action = @selector(wellChanged:);
    [self addArrangedSubview:_pop];
    [self addArrangedSubview:_well];
    return self;
}
- (void)picked:(NSString *)k {
    if ([k isEqualToString:@"custom"]) {
        [NSColorPanel sharedColorPanel].target = self;
        [NSColorPanel sharedColorPanel].action = @selector(wellChanged:);
        [[NSColorPanel sharedColorPanel] orderFront:nil];
        [_well activate:YES];
        return;
    }
    _key = k;
    _well.color = FSColorResolve(k);
    if (_cb) _cb(k);
}
- (void)wellChanged:(id)sender {
    NSString *k = [NSString stringWithFormat:@"custom:%@", FSColorHex(_well.color)];
    _key = k;
    if (_cb) _cb(k);
}
@end

// ---------- Stats 组件复刻：PreferencesRow / PreferencesSection ----------
static NSView *FSSpacer(void) {
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    [v setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return v;
}

// 行（Stats PreferencesRow：12pt 标题 + 右侧控件；上下 5/4pt）
static NSStackView *FSRow(NSString *title, NSView *control) {
    NSStackView *row = [NSStackView stackViewWithViews:@[]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    row.spacing = 0;
    row.edgeInsets = NSEdgeInsetsMake(5, 0, 4, 0);
    NSTextField *lab = FSText(FSL(title), 12, NSFontWeightRegular, [NSColor labelColor]);
    [lab setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addArrangedSubview:lab];
    [row addArrangedSubview:FSSpacer()];
    if (control) [row addArrangedSubview:control];
    return row;
}

// 分组（Stats PreferencesSection：可选标题 + 圆角 10 容器 + 组内 1pt 分隔线）
static NSStackView *FSSection(NSString *title, NSArray<NSView *> *rows) {
    NSStackView *col = [NSStackView stackViewWithViews:@[]];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeLeading;
    col.spacing = 0;

    if (title.length) {
        NSStackView *header = [NSStackView stackViewWithViews:@[]];
        header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        header.spacing = 8;
        [header.heightAnchor constraintEqualToConstant:26].active = YES;
        NSView *space = [[NSView alloc] initWithFrame:NSZeroRect];
        [space.widthAnchor constraintEqualToConstant:4].active = YES;
        NSTextField *t = FSText(FSL(title), 12, NSFontWeightMedium, [NSColor labelColor]);
        [header addArrangedSubview:space];
        [header addArrangedSubview:t];
        [header addArrangedSubview:FSSpacer()];
        [col addArrangedSubview:header];
        [header.widthAnchor constraintEqualToAnchor:col.widthAnchor].active = YES;
    }

    NSStackView *container = [NSStackView stackViewWithViews:@[]];
    container.orientation = NSUserInterfaceLayoutOrientationVertical;
    container.alignment = NSLayoutAttributeLeading;
    container.wantsLayer = YES;
    container.layer.backgroundColor = [[NSColor quaternaryLabelColor] colorWithAlphaComponent:0.025].CGColor;
    container.layer.cornerRadius = 10;
    container.edgeInsets = NSEdgeInsetsMake(8, 10, 8, 10);
    container.spacing = 8;
    [col addArrangedSubview:container];
    [container.widthAnchor constraintEqualToAnchor:col.widthAnchor].active = YES;

    BOOL first = YES;
    for (NSView *r in rows) {
        if (!first) {
            NSView *sep = [[NSView alloc] initWithFrame:NSZeroRect];
            sep.wantsLayer = YES;
            sep.layer.backgroundColor = [[NSColor separatorColor] colorWithAlphaComponent:0.05].CGColor;
            [sep.heightAnchor constraintEqualToConstant:1].active = YES;
            [container addArrangedSubview:sep];
            [sep.widthAnchor constraintEqualToAnchor:container.widthAnchor constant:-20].active = YES;
        }
        [container addArrangedSubview:r];
        [r.widthAnchor constraintEqualToAnchor:container.widthAnchor constant:-20].active = YES;
        first = NO;
    }
    return col;
}

// ---------- 空态 ----------
static NSView *FSEmptyView(NSString *msg) {
    NSStackView *v = [NSStackView stackViewWithViews:@[]];
    v.orientation = NSUserInterfaceLayoutOrientationVertical;
    v.alignment = NSLayoutAttributeCenterX;
    [v.heightAnchor constraintEqualToConstant:120].active = YES;
    NSTextField *t = FSText(FSL(msg), 12, NSFontWeightRegular, [NSColor secondaryLabelColor]);
    t.alignment = NSTextAlignmentCenter;
    [v addArrangedSubview:FSSpacer()];
    [v addArrangedSubview:t];
    [v addArrangedSubview:FSSpacer()];
    return v;
}

// ---------- 灰度图（对齐 Stats grayscaleImage） ----------
static NSImage *FSGrayscaleImage(NSImage *img) {
    NSData *tiff = [img TIFFRepresentation];
    if (!tiff) return img;
    CIImage *ci = [CIImage imageWithData:tiff];
    CIFilter *f = [CIFilter filterWithName:@"CIColorControls"];
    [f setValue:ci forKey:kCIInputImageKey];
    [f setValue:@0.0 forKey:kCIInputSaturationKey];
    CIImage *out = f.outputImage;
    static CIContext *ctx = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ ctx = [CIContext context]; });
    CGImageRef cg = [ctx createCGImage:out fromRect:out.extent];
    if (!cg) return img;
    NSImage *g = [[NSImage alloc] initWithCGImage:cg size:img.size];
    CGImageRelease(cg);
    return g;
}

// ---------- 侧边栏（Stats SidebarView / MenuItem） ----------
@interface FSSidebar : NSView
@property (nonatomic, copy) void (^onSelect)(NSString *page);
- (void)setActive:(NSString *)page;
@end

@interface FSSidebarRow : NSView
@property (nonatomic, copy) NSString *page;
@property (nonatomic, copy) void (^onClick)(NSString *page);
- (instancetype)initWithPage:(NSString *)page symbol:(NSString *)sym title:(NSString *)title;
- (void)setActiveState:(BOOL)active;
@end

@implementation FSSidebarRow {
    NSImageView *_iv;
    NSTextField *_tv;
}
- (instancetype)initWithPage:(NSString *)page symbol:(NSString *)sym title:(NSString *)title {
    self = [super initWithFrame:NSMakeRect(0, 0, 160, 32)];
    self.page = page;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 5;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self.heightAnchor constraintEqualToConstant:32].active = YES;
    _iv = [[NSImageView alloc] initWithFrame:NSMakeRect(8, 7, 18, 18)];
    _iv.image = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    _iv.contentTintColor = [NSColor labelColor];
    _tv = FSText(FSL(title), 13, NSFontWeightRegular, [NSColor labelColor]);
    _tv.frame = NSMakeRect(34, 8, 118, 16);
    [self addSubview:_iv];
    [self addSubview:_tv];
    return self;
}
- (void)setActiveState:(BOOL)active {
    if (active) {
        self.layer.backgroundColor = [NSColor selectedContentBackgroundColor].CGColor;
        _iv.contentTintColor = [NSColor whiteColor];
        _tv.textColor = [NSColor whiteColor];
    } else {
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
        _iv.contentTintColor = [NSColor labelColor];
        _tv.textColor = [NSColor labelColor];
    }
}
- (void)mouseDown:(NSEvent *)e {
    if (self.onClick) self.onClick(self.page);
}
@end

@implementation FSSidebar {
    NSMutableArray<FSSidebarRow *> *_rows;
    NSStackView *_list;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self.widthAnchor constraintEqualToConstant:180].active = YES;

    _list = [[FSFlipStack alloc] init];
    _list.orientation = NSUserInterfaceLayoutOrientationVertical;
    _list.alignment = NSLayoutAttributeLeading;
    _list.spacing = 0;
    _list.edgeInsets = NSEdgeInsetsMake(0, 8, 0, 8);
    _list.translatesAutoresizingMaskIntoConstraints = NO;

    // 菜单行：设置 + 间隔 + 模块
    _rows = [NSMutableArray array];
    __weak FSSidebar *weakSelf = self;
    void (^addRow)(NSString *, NSString *, NSString *) = ^(NSString *page, NSString *sym, NSString *title) {
        FSSidebar *sself = weakSelf;
        if (!sself) return;
        FSSidebarRow *r = [[FSSidebarRow alloc] initWithPage:page symbol:sym title:title];
        r.onClick = ^(NSString *p) { if (sself.onSelect) sself.onSelect(p); };
        [sself->_list addArrangedSubview:r];
        [r.widthAnchor constraintEqualToAnchor:sself->_list.widthAnchor constant:-16].active = YES;
        [sself->_rows addObject:r];
    };
    addRow(@"Settings", @"gearshape", @"Settings");
    NSView *sp = [[NSView alloc] initWithFrame:NSZeroRect];
    [sp.heightAnchor constraintEqualToConstant:10].active = YES;
    [_list addArrangedSubview:sp];

    for (NSString *m in FSBarAllModules()) {
        addRow(m, FSBarModuleSymbol(m), m);
    }

    // 底部工具行（45pt；对齐 Stats additionalButtons）
    NSStackView *bottom = [NSStackView stackViewWithViews:@[]];
    bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottom.distribution = NSStackViewDistributionFillEqually;
    bottom.alignment = NSLayoutAttributeCenterY;
    bottom.spacing = 0;
    bottom.translatesAutoresizingMaskIntoConstraints = NO;
    [bottom.heightAnchor constraintEqualToConstant:45].active = YES;
    void (^addBtn)(NSString *, NSString *, FSAct) = ^(NSString *sym, NSString *tip, FSAct cb) {
        NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil] target:nil action:nil];
        b.bezelStyle = NSBezelStyleRegularSquare;
        b.bordered = NO;
        b.imageScaling = NSImageScaleNone;
        b.contentTintColor = [NSColor secondaryLabelColor];
        b.toolTip = tip;
        b.focusRingType = NSFocusRingTypeNone;
        [b.widthAnchor constraintGreaterThanOrEqualToConstant:33].active = YES;
        FSSetAction(b, cb);
        [bottom addArrangedSubview:b];
    };
    addBtn(@"gearshape", FSL(@"Open application settings"), ^(id s) { if (weakSelf.onSelect) weakSelf.onSelect(@"Settings"); });
    addBtn(@"arrow.triangle.2.circlepath", FSL(@"Reimport from Stats"), ^(id s) {
        FSBarResetFromStats();
        if (weakSelf.onSelect) weakSelf.onSelect(@"Settings");
    });
    addBtn(@"power", FSL(@"Close application"), ^(id s) { [NSApp.keyWindow close]; });

    [self addSubview:_list];
    [self addSubview:bottom];
    [NSLayoutConstraint activateConstraints:@[
        [_list.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_list.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_list.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [bottom.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [bottom.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [bottom.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [bottom.heightAnchor constraintEqualToConstant:45],
    ]];
    return self;
}
- (void)setActive:(NSString *)page {
    for (FSSidebarRow *r in _rows) [r setActiveState:[r.page isEqualToString:page]];
}
@end

// ---------- 部件选择条（Stats WidgetSelectorView / WidgetPreview） ----------
static NSImage *FSScaleImage(NSImage *img, CGFloat maxH) {
    NSSize sz = img.size;
    if (sz.height <= maxH || sz.height <= 0) return img;
    CGFloat k = maxH / sz.height;
    NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(sz.width * k, maxH)];
    [out lockFocus];
    [img drawInRect:NSMakeRect(0, 0, sz.width * k, maxH) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [out unlockFocus];
    return out;
}

@interface FSWidgetChip : NSView
@property (nonatomic, copy) NSString *form;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, strong) NSImage *colorImg;
@property (nonatomic, strong) NSImage *grayImg;
- (void)refreshVisual;
@end

@implementation FSWidgetChip {
    NSImageView *_iv;
}
- (instancetype)initWithForm:(NSString *)form img:(NSImage *)img {
    CGFloat w = MAX(18, img.size.width + 4);
    self = [super initWithFrame:NSMakeRect(0, 0, w, 24)];
    self.form = form;
    self.colorImg = img;
    self.grayImg = FSGrayscaleImage(img);
    self.wantsLayer = YES;
    self.layer.cornerRadius = 2;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [NSColor colorWithSRGBRed:221/255.0 green:221/255.0 blue:221/255.0 alpha:1].CGColor;
    self.layer.backgroundColor = [NSColor whiteColor].CGColor;
    _iv = [[NSImageView alloc] initWithFrame:NSMakeRect(2, (24 - img.size.height) / 2, img.size.width, img.size.height)];
    _iv.imageScaling = NSImageScaleNone;
    [self addSubview:_iv];
    [self refreshVisual];
    return self;
}
- (void)refreshVisual {
    _iv.image = self.active ? self.colorImg : self.grayImg;
    _iv.alphaValue = self.active ? 1.0 : 0.75;
}
- (void)mouseEntered:(NSEvent *)e { [[NSCursor pointingHandCursor] set]; if (!self.active) { _iv.image = self.colorImg; _iv.alphaValue = 0.9; } }
- (void)mouseExited:(NSEvent *)e { [[NSCursor arrowCursor] set]; [self refreshVisual]; }
- (void)updateTrackingAreas {
    for (NSTrackingArea *ta in [self.trackingAreas copy]) [self removeTrackingArea:ta];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingActiveInActiveApp
                                                         owner:self userInfo:nil]];
}
@end

// 选择条：白底小卡横排 + 启用/停用分区 + 点击切换 + 拖拽排序
@interface FSWidgetSelector : NSView
- (instancetype)initWithModule:(NSString *)module onChanged:(void (^)(void))changed;
@end

@implementation FSWidgetSelector {
    NSString *_module;
    void (^_changed)(void);
    NSMutableArray<FSWidgetChip *> *_chips;
    NSVisualEffectView *_bg;
    NSView *_sep;
    FSWidgetChip *_dragging;
    BOOL _dragged;
    CGFloat _startX;
}
- (instancetype)initWithModule:(NSString *)module onChanged:(void (^)(void))changed {
    self = [super initWithFrame:NSMakeRect(0, 0, 520, 44)];
    _module = module;
    _changed = [changed copy];
    self.wantsLayer = NO;
    [self.heightAnchor constraintEqualToConstant:44].active = YES;

    _bg = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    _bg.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _bg.material = NSVisualEffectMaterialContentBackground;
    _bg.state = NSVisualEffectStateActive;
    _bg.wantsLayer = YES;
    _bg.layer.cornerRadius = 5;
    _bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_bg positioned:NSWindowBelow relativeTo:nil];

    _sep = [[NSView alloc] initWithFrame:NSZeroRect];
    _sep.wantsLayer = YES;
    _sep.layer.backgroundColor = [[NSColor separatorColor] colorWithAlphaComponent:0.15].CGColor;
    [self addSubview:_sep];

    _chips = [NSMutableArray array];
    NSArray *enabled = FSBarEnabledForms(module);
    for (NSString *form in FSBarFormsForModule(module)) {
        NSImage *img = FSBarRenderFormPreview(module, form, NO);
        FSWidgetChip *chip = [[FSWidgetChip alloc] initWithForm:form img:img];
        chip.active = [enabled containsObject:form];
        chip.toolTip = FSFormDisplayName(form);
        [_chips addObject:chip];
        [self addSubview:chip];
    }
    [self resortChips];
    [self layoutChips];
    return self;
}
// 分区稳定性：启用在前（保持相对次序），停用随后
- (void)resortChips {
    NSMutableArray *act = [NSMutableArray array], *inact = [NSMutableArray array];
    for (FSWidgetChip *c in _chips) [ (c.active ? act : inact) addObject:c];
    [_chips setArray:[act arrayByAddingObjectsFromArray:inact]];
}
- (NSUInteger)activeCount {
    NSUInteger n = 0;
    for (FSWidgetChip *c in _chips) if (c.active) n++;
    return n;
}
- (void)layoutChips {
    CGFloat x = 10;
    CGFloat y = (44 - 24) / 2;
    NSUInteger activeN = [self activeCount];
    BOOL firstActive = YES, firstInactive = YES;
    for (NSUInteger i = 0; i < _chips.count; i++) {
        FSWidgetChip *c = _chips[i];
        if (i == activeN) {   // 分隔线
            _sep.hidden = (activeN == 0 || activeN == _chips.count);
            _sep.frame = NSMakeRect(x, 9, 1, 26);
            x += 1 + 10;
        }
        if (i < activeN && !firstActive) { } // 间距统一处理
        (void)firstActive; (void)firstInactive;
        c.frame = NSMakeRect(x, y, c.frame.size.width, 24);
        x += c.frame.size.width + 10;
        [c updateTrackingAreas];
    }
    if (_chips.count == 0) _sep.hidden = YES;
}
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    FSWidgetChip *hit = nil;
    for (FSWidgetChip *c in _chips) if (NSPointInRect(p, c.frame)) { hit = c; break; }
    if (!hit) { [super mouseDown:e]; return; }
    _dragging = hit;
    _dragged = NO;
    _startX = p.x;
    __weak FSWidgetSelector *weakSelf = self;
    [self.window trackEventsMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                 timeout:NSTimeIntervalSince1970
                                    mode:NSEventTrackingRunLoopMode
                                 handler:^(NSEvent *ev, BOOL *stop) {
        FSWidgetSelector *sf = weakSelf;
        if (!sf) { *stop = YES; return; }
        NSPoint q = [sf convertPoint:ev.locationInWindow fromView:nil];
        if (ev.type == NSEventTypeLeftMouseDragged) {
            if (fabs(q.x - sf->_startX) > 2) sf->_dragged = YES;
            NSUInteger idx = [sf->_chips indexOfObject:sf->_dragging];
            // 计算目标位：与相邻卡中线比较
            NSInteger target = (NSInteger)idx;
            if (idx != NSNotFound) {
                if (idx > 0 && q.x < NSMidX(sf->_chips[idx - 1].frame)) target = (NSInteger)idx - 1;
                else if (idx + 1 < sf->_chips.count && q.x > NSMidX(sf->_chips[idx + 1].frame)) target = (NSInteger)idx + 1;
            }
            if (target != (NSInteger)idx && target >= 0 && target < (NSInteger)sf->_chips.count) {
                [sf->_chips removeObjectAtIndex:idx];
                [sf->_chips insertObject:sf->_dragging atIndex:target];
                // 跨分隔线 → 切换启用态
                BOOL overActive = target < (NSInteger)[sf activeCountAfterRemoving:sf->_dragging] ||
                                  sf->_dragging.active && target < (NSInteger)[sf activeCount];
                (void)overActive;
                BOOL newActive = target < (NSInteger)[sf activeCountForIndexHint:target];
                if (!sf->_dragging.active && newActive) sf->_dragging.active = YES;
                else if (sf->_dragging.active && !newActive) sf->_dragging.active = NO;
                [sf->_dragging refreshVisual];
                [sf resortChips];
                [sf layoutChips];
            }
        } else {
            if (!sf->_dragged) {
                sf->_dragging.active = !sf->_dragging.active;
                [sf->_dragging refreshVisual];
            }
            [sf persist];
            if (sf->_changed) sf->_changed();
            *stop = YES;
        }
    }];
}
// 拖拽目标判定辅助（简化：目标索引 < 当前启用数 → 属启用区）
- (NSUInteger)activeCountAfterRemoving:(FSWidgetChip *)chip { return [self activeCount]; }
- (NSUInteger)activeCountForIndexHint:(NSInteger)idx {
    // 分隔线以当前启用数计
    return [self activeCount];
}
- (void)persist {
    [self resortChips];
    [self layoutChips];
    NSMutableArray *enabled = [NSMutableArray array];
    NSUInteger i = 0;
    for (FSWidgetChip *c in _chips) {
        // Stats 位置键（同名互通）
        FSBarCfgSet(_module, c.form, @"position", @(i));
        if (c.active) [enabled addObject:c.form];
        i++;
    }
    FSBarSetEnabledForms(_module, enabled);
    FSBarReloadFromStore();
}
@end

// ---------- 部件设置块（Stats WidgetSettings：居中标题 + 白底图标座） ----------
static NSView *FSWidgetSettingsBlock(NSString *title, NSImage *image, NSView *settings) {
    NSStackView *block = [NSStackView stackViewWithViews:@[]];
    block.orientation = NSUserInterfaceLayoutOrientationVertical;
    block.spacing = 0;

    NSStackView *header = [NSStackView stackViewWithViews:@[]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.distribution = NSStackViewDistributionEqualCentering;
    header.edgeInsets = NSEdgeInsetsMake(6, 0, 6, 0);
    header.spacing = 0;
    NSStackView *content = [NSStackView stackViewWithViews:@[]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.spacing = 0;
    NSStackView *chip = [NSStackView stackViewWithViews:@[]];
    chip.orientation = NSUserInterfaceLayoutOrientationVertical;
    chip.spacing = 0;
    chip.wantsLayer = YES;
    chip.layer.backgroundColor = [NSColor whiteColor].CGColor;
    chip.layer.cornerRadius = 2;
    chip.edgeInsets = NSEdgeInsetsMake(2, 2, 2, 2);
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, image.size.width, image.size.height)];
    iv.image = image;
    [chip addArrangedSubview:iv];
    NSTextField *tv = FSText(title, 13, NSFontWeightRegular, [NSColor labelColor]);
    [content addArrangedSubview:chip];
    [content addArrangedSubview:tv];
    [header addArrangedSubview:FSSpacer()];
    [header addArrangedSubview:content];
    [header addArrangedSubview:FSSpacer()];
    [block addArrangedSubview:header];
    [header.widthAnchor constraintEqualToAnchor:block.widthAnchor].active = YES;
    if (settings) {
        [block addArrangedSubview:settings];
        [settings.widthAnchor constraintEqualToAnchor:block.widthAnchor].active = YES;
    }
    return block;
}

// ---------- 滚动容器 ----------
static NSScrollView *FSScroll(NSStackView **outStack, CGFloat spacing, NSEdgeInsets insets) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = NO;
    sv.autohidesScrollers = YES;
    sv.horizontalScrollElasticity = NSScrollElasticityNone;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.contentView.drawsBackground = NO;
    FSFlipStack *st = [[FSFlipStack alloc] init];
    st.orientation = NSUserInterfaceLayoutOrientationVertical;
    st.alignment = NSLayoutAttributeLeading;
    st.spacing = spacing;
    st.edgeInsets = insets;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    sv.documentView = st;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:sv.contentView.topAnchor],
        [st.leadingAnchor constraintEqualToAnchor:sv.contentView.leadingAnchor],
        [st.widthAnchor constraintEqualToAnchor:sv.contentView.widthAnchor],
    ]];
    *outStack = st;
    return sv;
}

// ---------- 每形态设置面板（逐项对齐 Stats .settings()） ----------
static NSView *FSFormSettingsView(NSString *module, NSString *form, void (^onChange)(void)) {
    NSString *m = module, *f = form;
    void (^setB)(NSString *, BOOL) = ^(NSString *k, BOOL v) { FSBarCfgSet(m, f, k, @(v)); FSBarReloadFromStore(); if (onChange) onChange(); };
    void (^setS)(NSString *, NSString *) = ^(NSString *k, NSString *v) { FSBarCfgSet(m, f, k, v); FSBarReloadFromStore(); if (onChange) onChange(); };
    BOOL (^getB)(NSString *, BOOL) = ^BOOL(NSString *k, BOOL d) { return FSBarCfgBool(m, f, k, d); };
    NSString *(^getS)(NSString *, NSString *) = ^NSString *(NSString *k, NSString *d) { return FSBarCfgStr(m, f, k, d); };

    NSMutableArray<NSView *> *cols = [NSMutableArray array];

    NSArray *scaleItems = @[@[@"none", @"None"], @[@"square", @"Square"], @[@"cube", @"Cube"], @[@"logarithmic", @"Logarithmic"]];
    NSArray *alignItems = @[@[@"left", @"Left alignment"], @[@"center", @"Center alignment"], @[@"right", @"Right alignment"]];
    NSArray *historyItems = @[@[@"30", @"30"], @[@"60", @"60"], @[@"90", @"90"], @[@"120", @"120"]];
    NSArray *pictogramItems = @[@[@"none", @"None"], @[@"separator", @""], @[@"dots", @"Dots"], @[@"arrows", @"Arrows"], @[@"chars", @"Characters"]];
    NSArray *pictogramColors = @[@[@"none", @"None"], @[@"separator", @""], @[@"default", @"Default color"],
                                 @[@"transparent", @"Transparent when no activity"], @[@"constant", @"Constant color"]];

    NSView *(^colorRow)(NSString *, NSString *) = ^NSView *(NSString *key, NSString *title) {
        FSColorPicker *p = [FSColorPicker picker:getS(key, @"system") cb:^(NSString *k) { setS(key, k); }];
        return FSRow(title, p);
    };
    NSView *(^switchRow)(NSString *, NSString *, BOOL) = ^NSView *(NSString *key, NSString *title, BOOL def) {
        return FSRow(title, FSNewSwitch(getB(key, def), ^(id s) { setB(key, ((NSSwitch *)s).state == NSControlStateValueOn); }));
    };
    NSView *(^selectRow)(NSString *, NSString *, NSArray *, NSString *) = ^NSView *(NSString *key, NSString *title, NSArray *items, NSString *def) {
        return FSRow(title, FSNewSelect(items, getS(key, def), ^(NSString *k) { setS(key, k); }));
    };

    if ([f isEqualToString:@"mini"]) {
        [cols addObject:FSSection(nil, @[
            switchRow(@"label", @"Label", ([m isEqualToString:@"Sensors"] || [m isEqualToString:@"Disk"])),
            colorRow(@"color", @"Color"),
            selectRow(@"alignment", @"Alignment", alignItems, @"left"),
        ])];
    } else if ([f isEqualToString:@"line_chart"]) {
        [cols addObject:FSSection(nil, @[
            switchRow(@"label", @"Label", NO),
            switchRow(@"value", @"Value", NO),
            switchRow(@"box", @"Box", YES),
            switchRow(@"frame", @"Frame", NO),
            colorRow(@"color", @"Color"),
            switchRow(@"valueColor", @"Colorize value", NO),
            selectRow(@"historyCount", @"Number of reads in the chart", historyItems, @"60"),
            selectRow(@"scale", @"Scaling", scaleItems, @"none"),
        ])];
    } else if ([f isEqualToString:@"bar_chart"]) {
        [cols addObject:FSSection(nil, @[
            switchRow(@"label", @"Label", NO),
            colorRow(@"color", @"Color"),
            switchRow(@"box", @"Box", YES),
            switchRow(@"frame", @"Frame", NO),
        ])];
    } else if ([f isEqualToString:@"pie_chart"] || [f isEqualToString:@"tachometer"]) {
        [cols addObject:FSSection(nil, @[
            switchRow(@"label", @"Label", NO),
            switchRow(@"monochrome", @"Monochrome accent", NO),
        ])];
    } else if ([f isEqualToString:@"network_chart"]) {
        [cols addObject:FSSection(nil, @[
            switchRow(@"label", @"Label", NO),
            switchRow(@"box", @"Box", NO),
            switchRow(@"frame", @"Frame", NO),
            switchRow(@"reversedOrder", @"Reverse order", NO),
            colorRow(@"downloadColor", @"Color of download"),
            colorRow(@"uploadColor", @"Color of upload"),
            selectRow(@"historyCount", @"Number of reads in the chart", historyItems, @"60"),
            selectRow(@"scale", @"Scaling", scaleItems, @"none"),
        ])];
    } else if ([f isEqualToString:@"speed"]) {
        NSArray *valueItems = @[@[@"oi", @"输出/输入"], @[@"io", @"输入/输出"],
                                @[@"o", @"输出"], @[@"i", @"输入"]];
        NSArray *modeItems = @[@[@"oneRow", @"One row"], @[@"twoRows", @"Two rows"]];
        [cols addObject:FSSection(nil, @[
            selectRow(@"displayValue", @"Value", valueItems, @"oi"),
            selectRow(@"mode", @"Display mode", modeItems, @"twoRows"),
        ])];
        [cols addObject:FSSection(nil, @[
            selectRow(@"icon", @"Pictogram", pictogramItems, @"dots"),
            selectRow(@"iconColor", @"Colorize", pictogramColors, @"default"),
            selectRow(@"iconAlignment", @"Alignment", @[@[@"left", @"Left alignment"], @[@"right", @"Right alignment"]], @"left"),
        ])];
        [cols addObject:FSSection(nil, @[
            switchRow(@"value", @"Value", YES),
            selectRow(@"valueColor", @"Colorize value", pictogramColors, @"default"),
            selectRow(@"valueAlignment", @"Alignment", alignItems, @"left"),
            switchRow(@"units", @"Units", YES),
        ])];
        [cols addObject:FSSection(nil, @[
            switchRow(@"monochrome", @"Monochrome accent", NO),
            colorRow(@"downloadColor", @"Color of download"),
            colorRow(@"uploadColor", @"Color of upload"),
        ])];
    } else if ([f isEqualToString:@"memory"]) {
        [cols addObject:FSSection(nil, @[
            colorRow(@"color", @"Color"),
            switchRow(@"symbols", @"Show symbols", YES),
            switchRow(@"orderReversed", @"Reverse order", NO),
        ])];
    } else if ([f isEqualToString:@"battery"]) {
        NSArray *addItems = @[@[@"none", @"None"], @[@"separator", @""],
                              @[@"percentage", @"Percentage"], @[@"time", @"Time"],
                              @[@"percentageAndTime", @"Percentage and time"], @[@"timeAndPercentage", @"Time and percentage"]];
        [cols addObject:FSSection(nil, @[
            selectRow(@"display", @"Additional information", addItems, @"percentage"),
            colorRow(@"color", @"Color"),
        ])];
    } else if ([f isEqualToString:@"icon"]) {
        NSArray *syms = @[@"cpu", @"memorychip", @"internaldrive", @"arrow.up.arrow.down",
                          @"thermometer.medium", @"battery.100", @"display", @"bolt.fill", @"fan"];
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *s in syms) [items addObject:@[s, s]];
        [cols addObject:FSSection(nil, @[selectRow(@"icon", @"Icon widget", items, @"cpu")])];
    } else {
        return nil;   // state / label 无设置
    }

    NSStackView *root = [NSStackView stackViewWithViews:@[]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 10;
    for (NSView *c in cols) {
        [root addArrangedSubview:c];
        [c.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
    }
    return root;
}

// ---------- 页面构建 ----------
static NSString *gCurrentPage = nil;
static NSWindow *gWin = nil;
static FSSidebar *gSidebar = nil;
static NSView *gHostContainer = nil;
static NSSwitch *gModuleToggle = nil;
static NSToolbarItem *gModuleToggleItem = nil;
static void FSSelectPage(NSString *page);
static int gInitialTab = 0;   // 快照用：0=模块 1=小组件
// v54：设置界面并入 App 设置窗口（性能监测 → 部件设置）——此标记表示已用内嵌模式，
// 不再创建独立 NSWindow（全局 gHostContainer/gSidebar 归内嵌视图所有）。
static BOOL gEmbedded = NO;
static NSView *gEmbeddedRoot = nil;

// 设置页（对齐 Stats ApplicationSettings 结构：信息块 + 分组）
static NSView *FSBuildSettingsPage(void) {
    NSStackView *stack = nil;
    NSScrollView *scroll = FSScroll(&stack, 10, NSEdgeInsetsMake(0, 10, 10, 10));

    // 信息块：图标 + 名称 + 版本（220pt）
    NSStackView *info = [NSStackView stackViewWithViews:@[]];
    info.orientation = NSUserInterfaceLayoutOrientationVertical;
    info.alignment = NSLayoutAttributeCenterX;
    info.spacing = 4;
    [info.heightAnchor constraintEqualToConstant:220].active = YES;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 96, 96)];
    icon.image = [NSApp applicationIconImage];
    [icon.widthAnchor constraintEqualToConstant:96].active = YES;
    [icon.heightAnchor constraintEqualToConstant:96].active = YES;
    NSTextField *name = FSText(@"Frset 监测", 20, NSFontWeightRegular, [NSColor labelColor]);
    name.alignment = NSTextAlignmentCenter;
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSTextField *verField = FSText([NSString stringWithFormat:@"%@ %@", FSL(@"Version"), ver], 12, NSFontWeightRegular, [NSColor labelColor]);
    verField.alignment = NSTextAlignmentCenter;
    [info addArrangedSubview:FSSpacer()];
    [info addArrangedSubview:icon];
    [info addArrangedSubview:name];
    [info addArrangedSubview:verField];
    [info addArrangedSubview:FSSpacer()];
    [stack addArrangedSubview:info];
    [info.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20].active = YES;

    // 合并模块（对齐 Stats Combined modules 分组）
    BOOL merged = FSBarMergedEnabled();
    NSMutableArray *layoutRows = [NSMutableArray array];
    [layoutRows addObject:FSRow(@"Combined modules", FSNewSwitch(merged, ^(id s) {
        FSBarGlobalSet(@"CombinedModules", @(((NSSwitch *)s).state == NSControlStateValueOn));
        FSBarReloadFromStore();
        FSSelectPage(@"Settings");
    }))];
    if (merged) {
        NSString *curSpacing = FSBarGlobalRaw(@"CombinedModules_spacing");
        if (![curSpacing isKindOfClass:[NSString class]]) curSpacing = @"none";
        NSArray *spacingItems = @[@[@"none", @"None"], @[@"1", @"1"], @[@"2", @"2"], @[@"3", @"3"],
                                  @[@"4", @"4"], @[@"5", @"5"], @[@"6", @"6"], @[@"7", @"7"], @[@"8", @"8"]];
        [layoutRows addObject:FSRow(@"Spacing", FSNewSelect(spacingItems, curSpacing, ^(NSString *k) {
            FSBarGlobalSet(@"CombinedModules_spacing", k);
            FSBarReloadFromStore();
        }))];
        [layoutRows addObject:FSRow(@"Separator", FSNewSwitch(FSBarMergedSeparator(), ^(id s) {
            FSBarGlobalSet(@"CombinedModules_separator", @(((NSSwitch *)s).state == NSControlStateValueOn));
            FSBarReloadFromStore();
        }))];
    }
    NSView *layoutSection = FSSection(nil, layoutRows);
    [stack addArrangedSubview:layoutSection];
    [layoutSection.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20].active = YES;

    // 配置管理（对齐 Stats 设置分组的按钮行样式）
    NSView *configSection = FSSection(nil, @[
        FSRow(@"Reimport from Stats", FSNewButton(@"Choose file", ^(id s) {
            FSBarResetFromStats();
            if (gCurrentPage) FSSelectPage(gCurrentPage);
        })),
        FSRow(@"Reset settings", FSNewButton(@"Reset", ^(id s) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = FSL(@"Reset settings");
            a.informativeText = @"将清除当前部件配置并恢复为出厂默认。";
            a.alertStyle = NSAlertStyleWarning;
            [a addButtonWithTitle:@"重置"];
            [a addButtonWithTitle:@"取消"];
            if ([a runModal] == NSAlertFirstButtonReturn) {
                FSBarResetToDefaults();
                if (gCurrentPage) FSSelectPage(gCurrentPage);
            }
        })),
    ]);
    [stack addArrangedSubview:configSection];
    [configSection.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20].active = YES;

    return scroll;
}

// 模块页（对齐 Stats Window.settings()：部件选择条 + [模块|小组件] 分段 + 选项卡）
static NSView *FSBuildModulePage(NSString *module) {
    NSView *root = [[NSView alloc] initWithFrame:NSZeroRect];
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(0, 10, 10, 10);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    __weak NSView *weakRoot = root;
    FSWidgetSelector *selector = [[FSWidgetSelector alloc] initWithModule:module onChanged:^{
        if (gCurrentPage) FSSelectPage(gCurrentPage);
        (void)weakRoot;
    }];
    [stack addArrangedSubview:selector];
    [selector.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20].active = YES;

    NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithLabels:@[FSL(@"Module"), FSL(@"Widgets")]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:nil action:nil];
    seg.segmentDistribution = NSSegmentDistributionFillEqually;
    [seg selectSegmentWithTag:gInitialTab];
    [stack addArrangedSubview:seg];
    [seg.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20].active = YES;

    NSView *tabHost = [[NSView alloc] initWithFrame:NSZeroRect];
    [stack addArrangedSubview:tabHost];
    [tabHost.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-20].active = YES;

    __weak NSView *weakTabHost = tabHost;
    void (^showTab)(NSInteger) = ^(NSInteger idx) {
        NSView *host = weakTabHost;
        if (!host) return;
        for (NSView *v in [host.subviews copy]) [v removeFromSuperview];
        NSStackView *st = nil;
        NSScrollView *scroll = nil;
        if (idx == 0) {
            // 模块设置页
            scroll = FSScroll(&st, 10, NSEdgeInsetsMake(0, 0, 0, 0));
            NSMutableArray *rows = [NSMutableArray array];
            // v54：内嵌设置没有工具栏开关 → 模块页顶部提供「在菜单栏显示」
            BOOL moduleEnabled = FSBarEnabledForms(module).count > 0;
            [rows addObject:FSRow(@"Show in menu bar", FSNewSwitch(moduleEnabled, ^(id s) {
                BOOL on = ((NSSwitch *)s).state == NSControlStateValueOn;
                if (on) {
                    NSArray *forms = FSBarEnabledForms(module);
                    if (forms.count == 0) {
                        NSArray *allForms = FSBarFormsForModule(module);
                        if (allForms.count) FSBarSetEnabledForms(module, @[allForms[0]]);
                    }
                } else {
                    FSBarSetEnabledForms(module, @[]);
                }
                FSBarReloadFromStore();
                if (gCurrentPage) FSSelectPage(gCurrentPage);
            }))];
            NSMutableArray *iv = [NSMutableArray array];
            for (NSNumber *n in @[@1, @2, @3, @5, @10, @15, @30, @60])
                [iv addObject:@[[n stringValue], [NSString stringWithFormat:@"%d 秒", n.intValue]]];
            int cur = FSBarCfgInt(module, nil, @"updateInterval", 1);
            [rows addObject:FSRow(@"Update interval", FSNewSelect(iv, [NSString stringWithFormat:@"%d", cur], ^(NSString *k) {
                FSBarCfgSet(module, nil, @"updateInterval", @([k intValue]));
                FSBarReloadFromStore();
            }))];
            NSView *sec1 = FSSection(nil, rows);
            [st addArrangedSubview:sec1];
            [sec1.widthAnchor constraintEqualToAnchor:st.widthAnchor constant:-20].active = YES;

            if ([module isEqualToString:@"Sensors"]) {
                char keys[200][8]; double vals[200];
                int n = FSBarCopySensorKeys(keys, vals, 200);
                NSMutableArray *items = [NSMutableArray array];
                for (int i = 0; i < n; i++) {
                    NSString *key = [NSString stringWithUTF8String:keys[i]];
                    [items addObject:@[key, key]];
                }
                if (items.count == 0) [items addObject:@[@"PPBR", @"PPBR"]];
                NSString *curSensor = FSBarCfgStr(module, nil, @"sensor", @"PPBR");
                NSView *sec2 = FSSection(nil, @[
                    FSRow(@"Sensor", FSNewSelect(items, curSensor, ^(NSString *k) {
                        FSBarCfgSet(module, nil, @"sensor", k);
                        FSBarReloadFromStore();
                    })),
                ]);
                [st addArrangedSubview:sec2];
                [sec2.widthAnchor constraintEqualToAnchor:st.widthAnchor constant:-20].active = YES;
            }
        } else {
            // 小组件设置页（Stats：无可用时显示 EmptyView；逐部件一个设置块）
            scroll = FSScroll(&st, 0, NSEdgeInsetsMake(0, 0, 0, 0));
            NSArray *active = FSBarEnabledForms(module);
            NSMutableArray *blocks = [NSMutableArray array];
            for (NSString *form in active) {
                if ([form isEqualToString:@"label"]) continue;   // Stats 排除 Label 部件
                NSImage *img = FSBarRenderFormPreview(module, form, NO);
                NSView *settings = FSFormSettingsView(module, form, ^{
                    // 选项变化时刷新选择条预览（宽度/内容可能变化）
                    if (gCurrentPage && [gCurrentPage isEqualToString:module]) FSSelectPage(module);
                });
                if (!settings) settings = [[NSView alloc] initWithFrame:NSZeroRect];
                NSView *block = FSWidgetSettingsBlock(FSFormDisplayName(form), img, settings);
                [blocks addObject:block];
                [st addArrangedSubview:block];
                [block.widthAnchor constraintEqualToAnchor:st.widthAnchor].active = YES;
            }
            if (blocks.count == 0) {
                NSView *empty = FSEmptyView(@"No available widgets to configure");
                [st addArrangedSubview:empty];
                [empty.widthAnchor constraintEqualToAnchor:st.widthAnchor].active = YES;
            }
        }
        scroll.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:scroll];
        [NSLayoutConstraint activateConstraints:@[
            [scroll.topAnchor constraintEqualToAnchor:host.topAnchor],
            [scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        ]];
        (void)st;
    };
    FSSetAction(seg, ^(id s) { showTab([(NSSegmentedControl *)s selectedSegment]); });
    showTab(gInitialTab);

    return root;
}

// ---------- 窗口与页面切换 ----------
@interface FSSettingsWindowDelegate : NSObject <NSToolbarDelegate, NSWindowDelegate>
+ (instancetype)shared;
@end
@implementation FSSettingsWindowDelegate
+ (instancetype)shared { static FSSettingsWindowDelegate *i; static dispatch_once_t o; dispatch_once(&o, ^{ i = [FSSettingsWindowDelegate new]; }); return i; }
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    if ([ident isEqualToString:@"moduleToggle"]) {
        gModuleToggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
        gModuleToggle.controlSize = NSControlSizeSmall;
        FSSetAction(gModuleToggle, ^(id s) {
            if (!gCurrentPage || [gCurrentPage isEqualToString:@"Settings"]) return;
            BOOL on = ((NSSwitch *)s).state == NSControlStateValueOn;
            if (on) {
                NSArray *forms = FSBarEnabledForms(gCurrentPage);
                if (forms.count == 0) {
                    NSArray *all = FSBarFormsForModule(gCurrentPage);
                    if (all.count) FSBarSetEnabledForms(gCurrentPage, @[all[0]]);
                }
            } else {
                FSBarSetEnabledForms(gCurrentPage, @[]);
            }
            FSBarReloadFromStore();
            FSSelectPage(gCurrentPage);
        });
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
        item.view = gModuleToggle;
        item.toolTip = FSL(@"Toggle the module");
        item.bordered = NO;
        item.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
        gModuleToggleItem = item;
        return item;
    }
    return nil;
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarFlexibleSpaceItemIdentifier, @"moduleToggle"];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarFlexibleSpaceItemIdentifier, @"moduleToggle"];
}
@end

static void FSEnsureWindow(void) {
    if (gWin) return;
    gWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 480)
                                       styleMask:(NSWindowStyleMaskClosable | NSWindowStyleMaskTitled |
                                                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView |
                                                  NSWindowStyleMaskResizable)
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    gWin.titlebarAppearsTransparent = YES;
    gWin.title = FSL(@"Settings");
    gWin.minSize = NSMakeSize(720, 480 - 42);
    gWin.releasedWhenClosed = NO;
    gWin.delegate = [FSSettingsWindowDelegate shared];
    [gWin setFrameAutosaveName:@"frset.stats.settings.window"];

    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"frset.stats.settings.toolbar"];
    tb.allowsUserCustomization = NO;
    tb.autosavesConfiguration = NO;
    tb.displayMode = NSToolbarDisplayModeDefault;
    tb.showsBaselineSeparator = YES;
    tb.delegate = [FSSettingsWindowDelegate shared];
    gWin.toolbar = tb;

    // 分栏：侧边栏(180) + 内容区
    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    gSidebar = [[FSSidebar alloc] initWithFrame:NSMakeRect(0, 0, 180, 480)];
    __weak FSSidebar *weakSidebar = gSidebar;
    gSidebar.onSelect = ^(NSString *page) { (void)weakSidebar; FSSelectPage(page); };
    NSViewController *sideVC = [[NSViewController alloc] init];
    sideVC.view = gSidebar;
    NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:sideVC];
    sideItem.canCollapse = NO;

    NSView *mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 480)];
    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:mainView.bounds];
    bg.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    bg.material = NSVisualEffectMaterialContentBackground;
    bg.state = NSVisualEffectStateActive;
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [mainView addSubview:bg positioned:NSWindowBelow relativeTo:nil];
    gHostContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 59, 540, 421)];
    gHostContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [mainView addSubview:gHostContainer];
    NSViewController *mainVC = [[NSViewController alloc] init];
    mainVC.view = mainView;
    NSSplitViewItem *mainItem = [NSSplitViewItem splitViewItemWithViewController:mainVC];
    mainItem.canCollapse = NO;
    [split addSplitViewItem:sideItem];
    [split addSplitViewItem:mainItem];
    gWin.contentViewController = split;

    if (![gWin setFrameUsingName:@"frset.stats.settings.window"]) [gWin center];
}

static void FSSelectPage(NSString *page) {
    if (!page) page = @"Settings";
    gCurrentPage = page;
    if (gSidebar) [gSidebar setActive:page];
    // v54：内嵌模式下宿主视图可能还没创建——只记录页码，创建时再渲染
    if (!gHostContainer) return;
    NSView *pageView = [page isEqualToString:@"Settings"] ? FSBuildSettingsPage() : FSBuildModulePage(page);
    for (NSView *v in [gHostContainer.subviews copy]) [v removeFromSuperview];
    pageView.translatesAutoresizingMaskIntoConstraints = NO;
    [gHostContainer addSubview:pageView];
    [NSLayoutConstraint activateConstraints:@[
        [pageView.topAnchor constraintEqualToAnchor:gHostContainer.topAnchor],
        [pageView.leadingAnchor constraintEqualToAnchor:gHostContainer.leadingAnchor],
        [pageView.trailingAnchor constraintEqualToAnchor:gHostContainer.trailingAnchor],
        [pageView.bottomAnchor constraintEqualToAnchor:gHostContainer.bottomAnchor],
    ]];
    if (gWin) gWin.title = FSL(page);
    BOOL modulePage = ![page isEqualToString:@"Settings"];
    if (gModuleToggle) {
        gModuleToggle.hidden = !modulePage;
        if (modulePage) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            gModuleToggle.state = FSBarEnabledForms(page).count > 0 ? NSControlStateValueOn : NSControlStateValueOff;
            [CATransaction commit];
        }
    }
    if (gWin && !gEmbedded) {
        [gWin makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    [gHostContainer layoutSubtreeIfNeeded];
}

// v54：内嵌设置视图（侧边栏 180 + 内容区 540）——供 App 设置窗口「性能监测 → 部件设置」页使用。
// 与独立窗口共用同一套页面构建代码；gSidebar / gHostContainer 全局指针在本视图生命周期内有效。
NSView *FSBarSettingsCreateEmbeddedView(void) {
    if (gEmbeddedRoot) return gEmbeddedRoot;
    gEmbedded = YES;

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 520)];

    gSidebar = [[FSSidebar alloc] initWithFrame:NSMakeRect(0, 0, 180, 520)];
    __weak FSSidebar *weakSidebar = gSidebar;
    gSidebar.onSelect = ^(NSString *page) { (void)weakSidebar; FSSelectPage(page); };
    [root addSubview:gSidebar];

    NSView *mainView = [[NSView alloc] initWithFrame:NSMakeRect(180, 0, 540, 520)];
    gHostContainer = [[NSView alloc] initWithFrame:mainView.bounds];
    gHostContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [mainView addSubview:gHostContainer];
    [root addSubview:mainView];

    gSidebar.translatesAutoresizingMaskIntoConstraints = NO;
    mainView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [gSidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [gSidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [gSidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [mainView.leadingAnchor constraintEqualToAnchor:gSidebar.trailingAnchor],
        [mainView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [mainView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [mainView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    gEmbeddedRoot = root;
    FSSelectPage(gCurrentPage ?: @"Settings");
    return root;
}

void FSBarSettingsOpen(void) {
    // v54：设置界面并入 App 设置窗口 → 深链跳到「性能监测 → 部件设置」页
    NSURL *url = [NSURL URLWithString:@"frsetnext://settings?pane=monitor.widgets"];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];

    // 自检：渲染各页面快照（FRSET_SETTINGSHOT=1）——仅在独立窗口模式可用
    if (getenv("FRSET_SETTINGSHOT") && *getenv("FRSET_SETTINGSHOT") && gWin && gHostContainer) {
        NSArray *all = [@[@"Settings"] arrayByAddingObjectsFromArray:FSBarAllModules()];
        for (NSString *page in all) {
            NSString *name = [page isEqualToString:@"Settings"] ? @"general" : page;
            for (int tab = 0; tab < 2; tab++) {
                if ([page isEqualToString:@"Settings"] && tab == 1) continue;
                gInitialTab = tab;
                FSSelectPage(page);
                [gWin.contentView layoutSubtreeIfNeeded];
                // 排障：layer-backed 控件缓存前 spin 主运行循环，让渲染服务器提交帧
                // （仅自检路径生效；FSNewSwitch 已禁初值动画，此处双保险）
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
                NSRect b = gWin.contentView.bounds;
                NSBitmapImageRep *rep = [gWin.contentView bitmapImageRepForCachingDisplayInRect:b];
                [gWin.contentView cacheDisplayInRect:b toBitmapImageRep:rep];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *fname = tab == 0 ? name : [name stringByAppendingString:@"_widgets"];
                [png writeToFile:[NSString stringWithFormat:@"/tmp/frset_settings_%@.png", fname] atomically:YES];
                NSLog(@"[FrsetStats] 设置快照: %@", fname);
            }
        }
        gInitialTab = 0;
    }
}

// v17：打开设置并直达指定模块页（弹窗头部 command 图标调用）
void FSBarSettingsOpenModule(NSString *module) {
    // v54：内嵌设置页里再选模块（侧边栏）；此入口先打开部件设置页
    FSBarSettingsOpen();
    if (module.length && gHostContainer) FSSelectPage(module);
}

// v55：Swift 设置页用 —— 传感器 key 列表（C 数组不便跨语言，这里转成 NSArray）
NSArray<NSString *> *FSBarSensorKeysList(void) {
    char keys[200][8];
    int n = FSBarCopySensorKeys(keys, NULL, 200);
    NSMutableArray *arr = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        NSString *k = [NSString stringWithUTF8String:keys[i]];
        if (k.length) [arr addObject:k];
    }
    return arr;
}
