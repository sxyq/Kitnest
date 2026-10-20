// frset_recorder.m — v47：屏幕录制（ScreenCaptureKit + AVAssetWriter）+ 设置小窗 + 计时窗
//   实现参照开源社区标准管线（CapSoftware/Cap、Apple "Capturing screen content"、
//   QuickRecorder、OBS mac-sck-audio-capture）：
//     SCStream(display filter + sourceRect) → CMSampleBuffer → AVAssetWriter(H.264 + AAC 双轨)
//   · 设置小窗：非激活置顶 NSPanel + NSVisualEffectView(.menu/behindWindow/Active) 毛玻璃
//   · 计时窗：同款毛玻璃药丸（红点 + M:SS + 停止），可拖动
//   · 区域选择：全屏 overlay（evenOdd 挖洞 + 白虚线选区 + 黄手柄 + 尺寸标签，ESC 取消 / 回车确认）
//   · 参数持久化：widgets.plist（FSBarCfg* 键 "Recorder_*"）
#import "frset_recorder.h"
#import "frset_barwidgets.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>
#import <dlfcn.h>

void FSBarLog(NSString *fmt, ...);

// ---- 配置存储见 frset_barwidgets.h（FSBarCfgRaw/Set/Bool/Str/Int，键 "Recorder_*"）----

#define ACCENT() [NSColor controlAccentColor]

// ============ 通用小元件 ============
// 玻璃层（macOS 26+ Liquid Glass；旧系统回退毛玻璃 menu(5)/behindWindow/Active）
// ⚠️ 父视图 drawRect 会被子视图盖住 —— 玻璃与内容必须分层：世界=玻璃，内容=玻璃上的子视图
static NSView *FSRecMakeGlass(NSRect r, CGFloat radius) {
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:r];
        g.style = NSGlassEffectViewStyleRegular;
        g.cornerRadius = radius;
        // 弹窗类玻璃要比主面板更实（设置项多、字小，不能让背后文字透上来）
        g.tintColor = [[NSColor windowBackgroundColor] colorWithAlphaComponent:0.78];
        return g;
    }
    NSVisualEffectView *g = [[NSVisualEffectView alloc] initWithFrame:r];
    g.material = NSVisualEffectMaterialMenu;
    g.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    g.state = NSVisualEffectStateActive;
    g.wantsLayer = YES;
    g.layer.cornerRadius = radius;
    g.layer.masksToBounds = YES;
    g.layer.backgroundColor = [NSColor clearColor].CGColor;
    return g;
}
// 给窗口装玻璃（contentView 换成玻璃，并把旧内容视图提为玻璃内容）
static void FSRecInstallGlass(NSPanel *panel, CGFloat radius) {
    NSView *content = panel.contentView;
    NSView *g = FSRecMakeGlass(content.bounds, radius);
    g.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    panel.contentView = g;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (@available(macOS 26.0, *)) {
        if ([g isKindOfClass:[NSGlassEffectView class]]) {
            ((NSGlassEffectView *)g).contentView = content;
            return;
        }
    }
    [g addSubview:content positioned:NSWindowBelow relativeTo:nil];
}

// 主屏高度（Cocoa 全局坐标 → CG 全局坐标换算用；主屏 origin=(0,0)）
static CGFloat FSRecMainScreenH(void) {
    NSScreen *m = [NSScreen screens].firstObject ?: [NSScreen mainScreen];
    return m.frame.size.height;
}
// Cocoa 全局矩形（屏幕.frame 即全局坐标）→ CG 全局矩形（左上原点）
static CGRect FSRecCG(CGRect cocoa) {
    CGFloat H = FSRecMainScreenH();
    return CGRectMake(cocoa.origin.x, H - (cocoa.origin.y + cocoa.size.height), cocoa.size.width, cocoa.size.height);
}

// ============ 设置模型（持久化） ============
@interface FSRecSettings : NSObject
@property (nonatomic) NSInteger fps;        // 15/24/30/60
@property (nonatomic) NSInteger resScale;   // 100/75/50（%）
@property (nonatomic) NSInteger areaMode;   // 0=整屏 1=区域
@property (nonatomic) NSInteger audioMode;  // 0=无 1=系统音 2=麦克风 3=系统+麦克风
@property (nonatomic) NSInteger format;     // 0=mov 1=mp4
@property (nonatomic, copy) NSString *dir;  // 保存目录
@property (nonatomic) CGRect region;        // CG 全局区域（areaMode=1 有效）
@property (nonatomic) CGDirectDisplayID regionDisplay;
+ (instancetype)shared;
- (void)load;
- (void)save;
@end

@implementation FSRecSettings
+ (instancetype)shared {
    static FSRecSettings *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; [s load]; });
    return s;
}
- (void)load {
    self.fps = FSBarCfgInt(@"Recorder", nil, @"fps", 30);
    self.resScale = FSBarCfgInt(@"Recorder", nil, @"resScale", 100);
    self.areaMode = FSBarCfgInt(@"Recorder", nil, @"areaMode", 0);
    self.audioMode = FSBarCfgInt(@"Recorder", nil, @"audioMode", 0);
    self.format = FSBarCfgInt(@"Recorder", nil, @"format", 1);
    NSString *movies = [NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES) firstObject] ?: NSHomeDirectory();
    self.dir = FSBarCfgStr(@"Recorder", nil, @"dir", movies);
    NSData *rd = (NSData *)FSBarCfgRaw(@"Recorder", nil, @"region");
    if ([rd isKindOfClass:[NSData class]] && rd.length >= (NSInteger)sizeof(CGRect) + (NSInteger)sizeof(CGDirectDisplayID)) {
        CGRect rr; CGDirectDisplayID did;
        [rd getBytes:&rr length:sizeof(CGRect)];
        [rd getBytes:&did range:NSMakeRange(sizeof(CGRect), sizeof(CGDirectDisplayID))];
        self.region = rr; self.regionDisplay = did;
    } else {
        self.region = CGRectZero; self.regionDisplay = 0;
    }
}
- (void)save {
    FSBarCfgSet(@"Recorder", nil, @"fps", @(self.fps));
    FSBarCfgSet(@"Recorder", nil, @"resScale", @(self.resScale));
    FSBarCfgSet(@"Recorder", nil, @"areaMode", @(self.areaMode));
    FSBarCfgSet(@"Recorder", nil, @"audioMode", @(self.audioMode));
    FSBarCfgSet(@"Recorder", nil, @"format", @(self.format));
    FSBarCfgSet(@"Recorder", nil, @"dir", self.dir);
    NSMutableData *d = [NSMutableData dataWithBytes:&_region length:sizeof(CGRect)];
    [d appendBytes:&_regionDisplay length:sizeof(CGDirectDisplayID)];
    FSBarCfgSet(@"Recorder", nil, @"region", d);
}
- (BOOL)needMic { return self.audioMode == 2 || self.audioMode == 3; }
- (BOOL)needSys { return self.audioMode == 1 || self.audioMode == 3; }
- (BOOL)isGIF { return self.format == 2; }
// GIF 不是 AVAssetWriter 能直接写的容器：先落成 mov，停止后再转 GIF 并删临时文件
- (NSString *)ext { return self.format == 1 ? @"mp4" : @"mov"; }
- (NSString *)fileType { return self.format == 1 ? (NSString *)AVFileTypeMPEG4 : (NSString *)AVFileTypeQuickTimeMovie; }
@end

// ============ GIF 导出（纯系统 API，不依赖 ffmpeg） ============
// 参照 ZTools「录屏生成GIF」插件的产物形态：录完转成循环 GIF。
// 与插件不同的是：插件内置 FFmpeg，本机没有，所以用 AVAssetImageGenerator 抽帧
// + ImageIO 写 GIF。代价是没有调色板优化、体积偏大，因此这里把宽度压到 ≤720px、
// 帧率压到 ≤12fps，够做操作演示。
//
// GIF 不是 AVAssetWriter 能直接写的容器：录制阶段仍落成 mov 临时文件，
// 停止后再转换，转完立刻删掉临时 mov（避免用户目录里留一堆半成品）。

static CGImageRef FSRecCreateScaledImage(CGImageRef src, CGFloat maxWidth) {
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    if (w == 0 || h == 0) return NULL;
    if ((CGFloat)w <= maxWidth) return NULL;          // 不需要缩放
    CGFloat scale = maxWidth / (CGFloat)w;
    size_t nw = MAX(1, (size_t)lround(w * scale));
    size_t nh = MAX(1, (size_t)lround(h * scale));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, 0, space,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, nw, nh), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

/// 把 mov 转成循环 GIF；成功返回 gif 路径，失败返回 nil
static NSString *FSRecConvertMovieToGIF(NSString *moviePath, NSString *gifPath,
                                        NSInteger fps, CGFloat maxWidth) {
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:moviePath]];
    if (!asset) return nil;
    NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
    if (!isfinite(duration) || duration <= 0.05) return nil;

    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;

    NSInteger gifFPS = MIN(MAX(4, fps), 12);
    NSTimeInterval step = 1.0 / (NSTimeInterval)gifFPS;
    NSInteger frameCount = (NSInteger)floor(duration / step);
    frameCount = MIN(MAX(frameCount, 1), 900);        // 上限 900 帧，防爆内存

    NSURL *outURL = [NSURL fileURLWithPath:gifPath];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)outURL, CFSTR("com.compuserve.gif"), (size_t)frameCount, NULL);
    if (!dest) return nil;

    // 无限循环
    NSDictionary *fileProps = @{ @"{GIF}": @{ @"LoopCount": @0 } };
    CGImageDestinationSetProperties(dest, (__bridge CFDictionaryRef)fileProps);
    NSDictionary *frameProps = @{ @"{GIF}": @{ @"DelayTime": @(step) } };

    NSInteger written = 0;
    for (NSInteger i = 0; i < frameCount; i++) {
        CMTime time = CMTimeMakeWithSeconds(i * step, 600);
        CGImageRef frame = [generator copyCGImageAtTime:time actualTime:NULL error:NULL];
        if (!frame) continue;
        CGImageRef scaled = FSRecCreateScaledImage(frame, maxWidth);
        CGImageDestinationAddImage(dest, scaled ?: frame,
                                   (__bridge CFDictionaryRef)frameProps);
        if (scaled) CGImageRelease(scaled);
        CGImageRelease(frame);
        written++;
    }
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    if (!ok || written == 0) {
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:NULL];
        return nil;
    }
    return gifPath;
}

// ============ 区域选择 overlay ============
@interface FSRegionView : NSView@property (nonatomic, copy) void (^onDone)(CGRect cg, CGDirectDisplayID did);
@property (nonatomic, copy) void (^onCancel)(void);
@property (nonatomic) CGRect drag;        // 本视图坐标
@property (nonatomic) BOOL dragging;
@property (nonatomic) CGDirectDisplayID displayID;
@end

@implementation FSRegionView
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)drawRect:(NSRect)dirty {
    CGFloat H = NSHeight(self.bounds);
    // v62：遮罩从「整屏 evenOdd 路径」改为 **4 个矩形**（全屏 7.6M 像素下路径填充很贵，是框选卡顿主因之一）
    NSRect sel = self.dragging ? self.drag : CGRectZero;
    [[[NSColor blackColor] colorWithAlphaComponent:0.45] setFill];
    if (CGRectIsEmpty(sel)) {
        NSRectFill(self.bounds);
    } else {
        NSRect f = NSMakeRect(sel.origin.x, H - (sel.origin.y + sel.size.height), sel.size.width, sel.size.height);
        if (f.origin.y > 0) NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), f.origin.y));
        CGFloat by = NSMaxY(f);
        if (by < H) NSRectFill(NSMakeRect(0, by, NSWidth(self.bounds), H - by));
        if (f.origin.x > 0) NSRectFill(NSMakeRect(0, f.origin.y, f.origin.x, f.size.height));
        CGFloat rx = NSMaxX(f);
        if (rx < NSWidth(self.bounds)) NSRectFill(NSMakeRect(rx, f.origin.y, NSWidth(self.bounds) - rx, f.size.height));
    }
    if (!CGRectIsEmpty(sel)) {
        NSRect f = NSMakeRect(sel.origin.x, H - (sel.origin.y + sel.size.height), sel.size.width, sel.size.height);
        // 白虚线边框 + 三等分线
        NSBezierPath *b = [NSBezierPath bezierPathWithRect:f];
        CGFloat dash[2] = {4, 4};
        [b setLineDash:dash count:2 phase:0];
        b.lineWidth = 1.5;
        [[[NSColor whiteColor] colorWithAlphaComponent:0.9] setStroke];
        [b stroke];
        // 8 手柄（黄）
        [[NSColor systemYellowColor] setFill];
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
            if (i == 1 && j == 1) continue;
            CGFloat hx = f.origin.x + f.size.width * i / 2.0 - 4;
            CGFloat hy = f.origin.y + f.size.height * j / 2.0 - 4;
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(hx, hy, 8, 8)] fill];
        }
        // 尺寸标签
        NSString *t = [NSString stringWithFormat:@"%d × %d", (int)sel.size.width, (int)sel.size.height];
        NSDictionary *a = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: NSColor.whiteColor};
        NSSize ts = [t sizeWithAttributes:a];
        NSRect lb = NSMakeRect(f.origin.x + f.size.width / 2.0 - ts.width / 2.0 - 6, f.origin.y - 24, ts.width + 12, 18);
        if (lb.origin.y < 2) lb.origin.y = NSMaxY(f) + 6;
        [[[NSColor blackColor] colorWithAlphaComponent:0.55] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:lb xRadius:9 yRadius:9] fill];
        [t drawAtPoint:NSMakePoint(lb.origin.x + 6, lb.origin.y + 3) withAttributes:a];
    } else {
        NSString *t = @"拖拽选择录制区域 · ESC 取消 · 回车确认";
        NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [[NSColor whiteColor] colorWithAlphaComponent:0.85]};
        NSSize ts = [t sizeWithAttributes:a];
        NSPoint p = NSMakePoint(NSMidX(self.bounds) - ts.width / 2.0, NSMidY(self.bounds) - ts.height / 2.0);
        [[[NSColor blackColor] colorWithAlphaComponent:0.45] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(p.x - 10, p.y - 6, ts.width + 20, ts.height + 12) xRadius:12 yRadius:12] fill];
        [t drawAtPoint:p withAttributes:a];
    }
}
- (NSPoint)clampPoint:(NSPoint)p {
    p.x = MIN(MAX(p.x, 0), NSWidth(self.bounds));
    p.y = MIN(MAX(p.y, 0), NSHeight(self.bounds));
    return p;
}
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self clampPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    self.drag = CGRectMake(p.x, p.y, 0, 0);
    self.dragging = YES;
    [self setNeedsDisplayInRect:CGRectInset(self.drag, -8, -8)];
}
- (void)mouseDragged:(NSEvent *)e {
    if (!self.dragging) return;
    CGRect old = self.drag;
    NSPoint p = [self clampPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    self.drag = CGRectMake(MIN(self.drag.origin.x, p.x), MIN(self.drag.origin.y, p.y),
                           fabs(p.x - self.drag.origin.x), fabs(p.y - self.drag.origin.y));
    // v62：只失效变化区（整屏 setNeedsDisplay 会让 7.6M 像素每帧重绘）
    CGRect u = CGRectUnion(CGRectInset(old, -6, -30), CGRectInset(self.drag, -6, -30));
    [self setNeedsDisplayInRect:u];
}
- (void)mouseUp:(NSEvent *)e {
    if (!self.dragging) return;
    self.dragging = NO;
    if (self.drag.size.width < 20 || self.drag.size.height < 20) {   // 太小：重置
        self.drag = CGRectZero;
        [self setNeedsDisplay:YES];
        return;
    }
    [self confirm];
}
- (void)confirm {
    if (CGRectIsEmpty(self.drag) || self.drag.size.width < 20 || self.drag.size.height < 20) return;
    NSScreen *sc = self.window.screen ?: [NSScreen mainScreen];
    // 本视图坐标 → Cocoa 全局 → CG 全局
    CGRect cocoa = NSMakeRect(sc.frame.origin.x + self.drag.origin.x,
                              sc.frame.origin.y + self.drag.origin.y,
                              self.drag.size.width, self.drag.size.height);
    FSBarLog(@"[录屏] 选区确认：%@（display=%u）", NSStringFromRect(self.drag), (unsigned)self.displayID);
    if (self.onDone) self.onDone(FSRecCG(cocoa), self.displayID);
}
- (void)cancel { if (self.onCancel) self.onCancel(); }
- (BOOL)canBecomeKeyView { return YES; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 53) { [self cancel]; }                    // ESC
    else if (e.keyCode == 36) { [self confirm]; }             // Return
    else [super keyDown:e];
}
@end

static NSMutableArray *g_regionWins = nil;

static void FSRegionOverlayShow(void (^onDone)(CGRect, CGDirectDisplayID), void (^onCancel)(void)) {
    [g_regionWins makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];
    g_regionWins = [NSMutableArray array];
    for (NSScreen *sc in [NSScreen screens]) {
        NSPanel *p = [[NSPanel alloc] initWithContentRect:sc.frame
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        p.level = NSFloatingWindowLevel + 20;
        p.ignoresMouseEvents = NO;
        p.opaque = NO;
        p.backgroundColor = [NSColor clearColor];
        p.releasedWhenClosed = NO;
        p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        CGDirectDisplayID did = ((NSNumber *)sc.deviceDescription[@"NSScreenNumber"]).unsignedIntValue;
        FSRegionView *v = [[FSRegionView alloc] initWithFrame:NSMakeRect(0, 0, sc.frame.size.width, sc.frame.size.height)];
        v.displayID = did;
        v.onDone = onDone; v.onCancel = onCancel;
        p.contentView = v;
        [p makeKeyWindow];
        [p orderFrontRegardless];
        [g_regionWins addObject:p];
    }
    FSBarLog(@"[录屏] 区域选择 overlay 已展开（%lu 屏）", (unsigned long)[NSScreen screens].count);
}
static void FSRegionOverlayClose(void) {
    [g_regionWins makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];
    g_regionWins = nil;
}

// ============ 计时窗（毛玻璃药丸） ============
static NSPanel *g_barWin = nil;
static CFAbsoluteTime g_barT0 = 0;
static dispatch_source_t g_barTick = NULL;

@interface FSRecBarBox : NSView
@end
@implementation FSRecBarBox
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)drawRect:(NSRect)dirty {
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    // 毛玻璃底
    [[[NSColor controlBackgroundColor] colorWithAlphaComponent:0.62] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.height / 2.0 yRadius:r.size.height / 2.0] fill];
    [[[NSColor separatorColor] colorWithAlphaComponent:0.4] setStroke];
    NSBezierPath *bd = [NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.height / 2.0 yRadius:r.size.height / 2.0];
    bd.lineWidth = 1; [bd stroke];
    // 红点
    [[NSColor colorWithSRGBRed:1.0 green:0.28 blue:0.25 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(13, NSMidY(r) - 3.5, 7, 7)] fill];
    // 计时
    NSUInteger secs = (NSUInteger)(g_barT0 > 0 ? (CFAbsoluteTimeGetCurrent() - g_barT0) : 0);
    NSString *t = [NSString stringWithFormat:@"%02lu:%02lu", (unsigned long)(secs / 60), (unsigned long)(secs % 60)];
    NSDictionary *ta = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: NSColor.labelColor};
    NSSize ts = [t sizeWithAttributes:ta];
    [t drawAtPoint:NSMakePoint(27, NSMidY(r) - ts.height / 2.0 - 0.5) withAttributes:ta];
    // 停止钮
    NSRect btn = NSMakeRect(NSMaxX(r) - 27, NSMidY(r) - 7, 14, 14);
    [[[NSColor separatorColor] colorWithAlphaComponent:0.55] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:btn xRadius:4 yRadius:4] fill];
    [[NSColor secondaryLabelColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(btn, 4, 4) xRadius:1.5 yRadius:1.5] fill];
}
- (void)mouseDown:(NSEvent *)e {
    if ([self convertPoint:e.locationInWindow fromView:nil].x >= NSWidth(self.bounds) - 30) FSScreenRecStop();
}
- (void)mouseDragged:(NSEvent *)e {
    NSPoint m = [NSEvent mouseLocation];
    NSRect f = self.window.frame;
    [self.window setFrameOrigin:NSMakePoint(m.x - f.size.width / 2.0, m.y - f.size.height / 2.0)];
}
@end

static void FSRecBarShow(void) {
    if (g_barWin) { [g_barWin orderFrontRegardless]; return; }
    NSScreen *sc = [NSScreen mainScreen];
    CGFloat w = 112, h = 30;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(NSMidX(sc.visibleFrame) - w / 2.0, NSMaxY(sc.visibleFrame) - h - 90, w, h)
        styleMask:NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered defer:NO];
    p.level = NSFloatingWindowLevel + 3;
    p.releasedWhenClosed = NO;
    p.opaque = NO;
    p.backgroundColor = [NSColor clearColor];
    p.ignoresMouseEvents = NO;
    FSRecBarBox *v = [[FSRecBarBox alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    p.contentView = v;
    FSRecInstallGlass(p, h / 2.0);          // v 成为玻璃下的内容子视图
    [p orderFrontRegardless];
    g_barWin = p;
    g_barT0 = CFAbsoluteTimeGetCurrent();
    g_barTick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_barTick, DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_barTick, ^{ [v setNeedsDisplay:YES]; });
    dispatch_resume(g_barTick);
    FSBarLog(@"[录屏] 计时窗已显示");
}
static void FSRecBarHide(void) {
    if (g_barTick) { dispatch_source_cancel(g_barTick); g_barTick = NULL; }
    if (g_barWin) { [g_barWin orderOut:nil]; g_barWin = nil; }
}

// ============ 设置小窗 ============
@interface FSRecPanelView : NSView
@property (nonatomic, weak) NSPanel *panel;
@property (nonatomic) NSInteger hoverRow;   // -1 无
@property (nonatomic) NSInteger hoverBtn;   // 0=无 1=更改目录 3=开始 9=关闭
@property (nonatomic) NSMutableArray *segGroups;   // @[@{@"rect":NSValue, @"items":@[..]}]
@end

@implementation FSRecPanelView
- (BOOL)isOpaque { return NO; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (NSArray *)segItems:(NSString *)key {
    if ([key isEqualToString:@"fps"]) return @[@"15", @"24", @"30", @"60"];
    if ([key isEqualToString:@"resScale"]) return @[@"原始", @"75%", @"50%"];
    if ([key isEqualToString:@"areaMode"]) return @[@"整个屏幕", @"选择区域"];
    if ([key isEqualToString:@"audioMode"]) return @[@"无", @"系统音", @"麦克风", @"系统+麦克"];
       if ([key isEqualToString:@"format"]) return @[@"MOV", @"MP4", @"GIF"];
    return @[];
}
- (NSInteger)segValue:(NSString *)key {
    FSRecSettings *s = [FSRecSettings shared];
    if ([key isEqualToString:@"fps"]) {
        NSArray *v = @[@15, @24, @30, @60];
        NSUInteger i = [v indexOfObject:@(s.fps)];
        return i == NSNotFound ? 2 : (NSInteger)i;
    }
    if ([key isEqualToString:@"resScale"]) {
        NSArray *v = @[@100, @75, @50];
        NSUInteger i = [v indexOfObject:@(s.resScale)];
        return i == NSNotFound ? 0 : (NSInteger)i;
    }
    if ([key isEqualToString:@"areaMode"]) return s.areaMode;
    if ([key isEqualToString:@"audioMode"]) return s.audioMode;
    if ([key isEqualToString:@"format"]) return s.format;
    return 0;
}
- (void)segSet:(NSString *)key index:(NSInteger)i {
    FSRecSettings *s = [FSRecSettings shared];
    if ([key isEqualToString:@"fps"]) s.fps = [@[@15, @24, @30, @60][i] integerValue];
    else if ([key isEqualToString:@"resScale"]) s.resScale = [@[@100, @75, @50][i] integerValue];
    else if ([key isEqualToString:@"areaMode"]) s.areaMode = i;
    else if ([key isEqualToString:@"audioMode"]) s.audioMode = i;
    else if ([key isEqualToString:@"format"]) s.format = i;
    [s save];
}
- (NSArray *)rows {
    return @[
        @{@"key": @"fps",       @"label": @"帧率"},
        @{@"key": @"resScale",  @"label": @"分辨率"},
        @{@"key": @"areaMode",  @"label": @"区域"},
        @{@"key": @"audioMode", @"label": @"声音来源"},
        @{@"key": @"format",    @"label": @"格式"},
    ];
}

- (void)drawRect:(NSRect)dirty {
    FSRecSettings *s = [FSRecSettings shared];
    NSDictionary *la = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
                         NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    NSDictionary *va = @{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: NSColor.labelColor};
    NSDictionary *ha = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                         NSForegroundColorAttributeName: NSColor.labelColor};
    // 标题
    [@"录屏设置" drawAtPoint:NSMakePoint(18, 14) withAttributes:ha];
    // 关闭钮（右上）
    NSRect xr = NSMakeRect(NSWidth(self.bounds) - 34, 14, 20, 20);
    BOOL hx = self.hoverBtn == 9;
    if (hx) { [[[NSColor separatorColor] colorWithAlphaComponent:0.35] setFill];
              [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(xr, 2, 2) xRadius:5 yRadius:5] fill]; }
    [[NSColor secondaryLabelColor] setStroke];
    NSBezierPath *xp = [NSBezierPath bezierPath];
    [xp moveToPoint:NSMakePoint(NSMidX(xr) - 5, NSMidY(xr) - 5)]; [xp lineToPoint:NSMakePoint(NSMidX(xr) + 5, NSMidY(xr) + 5)];
    [xp moveToPoint:NSMakePoint(NSMidX(xr) + 5, NSMidY(xr) - 5)]; [xp lineToPoint:NSMakePoint(NSMidX(xr) - 5, NSMidY(xr) + 5)];
    xp.lineWidth = 1.4; [xp stroke];

    // 设置行（label + 分段控件）
    CGFloat y = 44;
    NSMutableArray *groups = [NSMutableArray array];
    for (NSDictionary *row in [self rows]) {
        NSString *key = row[@"key"];
        [row[@"label"] drawAtPoint:NSMakePoint(18, y + 4) withAttributes:la];
        NSArray *items = [self segItems:key];
        NSInteger sel = [self segValue:key];
        CGFloat gx = 18 + 96, gw = NSWidth(self.bounds) - 96 - 36;
        NSRect gr = NSMakeRect(gx, y, gw, 22);
        [groups addObject:@{@"rect": [NSValue valueWithRect:gr], @"sel": @(sel), @"items": items}];
        // 槽
        [[[NSColor separatorColor] colorWithAlphaComponent:0.22] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:gr xRadius:5 yRadius:5] fill];
        CGFloat segW = gr.size.width / items.count;
        // 选中胶囊
        NSRect pill = NSMakeRect(gr.origin.x + sel * segW + 1.5, gr.origin.y + 1.5, segW - 3, gr.size.height - 3);
        [[ACCENT() colorWithAlphaComponent:0.85] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:4 yRadius:4] fill];
        for (NSUInteger i = 0; i < items.count; i++) {
            NSRect ir = NSMakeRect(gr.origin.x + i * segW, gr.origin.y, segW, gr.size.height);
            NSDictionary *ia = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: i == (NSUInteger)sel ? NSColor.whiteColor : NSColor.labelColor};
            NSSize is = [items[i] sizeWithAttributes:ia];
            [items[i] drawAtPoint:NSMakePoint(NSMidX(ir) - is.width / 2.0, NSMidY(ir) - is.height / 2.0 - 0.5) withAttributes:ia];
        }
        y += 30;
    }
    self.segGroups = groups;

    // 保存位置行（过长则逐级上缩，tooltip 显示全路径）
    [@"保存到" drawAtPoint:NSMakePoint(18, y + 4) withAttributes:la];
    NSDictionary *da = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular],
                         NSForegroundColorAttributeName: NSColor.labelColor,
                         NSToolTipAttributeName: s.dir};
    NSString *dirFull = s.dir;
    NSMutableAttributedString *ds = [[NSMutableAttributedString alloc] initWithString:dirFull attributes:da];
    while ([dirFull sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11.5]}].width > 150 && dirFull.length > 4) {
        dirFull = [dirFull stringByDeletingLastPathComponent];
        if (!dirFull.length) break;
        ds = [[NSMutableAttributedString alloc] initWithString:dirFull attributes:da];
    }
    [ds drawAtPoint:NSMakePoint(18 + 96, y + 4)];
    // [更改…]
    NSRect cbr = NSMakeRect(NSWidth(self.bounds) - 18 - 56, y, 56, 22);
    BOOL hc = self.hoverBtn == 1;
    [[[NSColor controlBackgroundColor] colorWithAlphaComponent:hc ? 0.95 : 0.7] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:cbr xRadius:5 yRadius:5] fill];
    NSDictionary *ca = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: NSColor.labelColor};
    NSSize cs = [@"更改…" sizeWithAttributes:ca];
    [@"更改…" drawAtPoint:NSMakePoint(NSMidX(cbr) - cs.width / 2.0, NSMidY(cbr) - cs.height / 2.0 - 0.5) withAttributes:ca];
    y += 30;

    // 区域已选提示（areaMode=1 时显示当前选区）
    if (s.areaMode == 1 && !CGRectIsEmpty(s.region)) {
        NSString *t = [NSString stringWithFormat:@"已选区域 %d×%d", (int)s.region.size.width, (int)s.region.size.height];
        NSDictionary *ra = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: NSColor.tertiaryLabelColor};
        [t drawAtPoint:NSMakePoint(18, y + 2) withAttributes:ra];
        y += 22;
    }

    // 开始录制按钮
    NSRect br = NSMakeRect(18, NSHeight(self.bounds) - 40, NSWidth(self.bounds) - 36, 28);
    BOOL hb = self.hoverBtn == 3;
    [[ACCENT() colorWithAlphaComponent:hb ? 1.0 : 0.9] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:br xRadius:6 yRadius:6] fill];
    NSDictionary *ba = @{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                         NSForegroundColorAttributeName: NSColor.whiteColor};
    NSSize bs = [@"开始录制" sizeWithAttributes:ba];
    [@"开始录制" drawAtPoint:NSMakePoint(NSMidX(br) - bs.width / 2.0, NSMidY(br) - bs.height / 2.0 - 0.5) withAttributes:ba];
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    FSRecSettings *s = [FSRecSettings shared];
    // 关闭
    if (p.x >= NSWidth(self.bounds) - 34 && p.y < 34) { FSScreenRecCloseSettings(); return; }
    // 分段
    for (NSDictionary *g in self.segGroups) {
        NSRect r = [g[@"rect"] rectValue];
        if (NSPointInRect(p, r)) {
            NSArray *items = g[@"items"];
            NSUInteger idx = (NSUInteger)((p.x - r.origin.x) / (r.size.width / items.count));
            if (idx >= items.count) idx = items.count - 1;
            NSArray *keys = @[@"fps", @"resScale", @"areaMode", @"audioMode", @"format"];
            NSUInteger gi = [self.segGroups indexOfObject:g];
            [self segSet:keys[MIN(gi, keys.count - 1)] index:(NSInteger)idx];
            if ([keys[gi] isEqualToString:@"areaMode"]) {
                if (idx == 1 && CGRectIsEmpty(s.region)) {   // 选「选择区域」且未选过 → 直接进选区
                    [self pickRegion];
                }
            }
            [self setNeedsDisplay:YES];
            return;
        }
    }
    // 更改目录
    NSRect cbr = NSMakeRect(NSWidth(self.bounds) - 18 - 56, [self rows].count * 30 + 44, 56, 22);
    if (NSPointInRect(p, cbr)) { [self pickDir]; return; }
    // 开始
    NSRect br = NSMakeRect(18, NSHeight(self.bounds) - 40, NSWidth(self.bounds) - 36, 28);
    if (NSPointInRect(p, br)) { FSScreenRecBeginFromSettings(); return; }
}
- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger hb = 0;
    if (p.x >= NSWidth(self.bounds) - 34 && p.y < 34) hb = 9;
    else if (NSPointInRect(p, NSMakeRect(NSWidth(self.bounds) - 18 - 56, [self rows].count * 30 + 44, 56, 22))) hb = 1;
    else if (NSPointInRect(p, NSMakeRect(18, NSHeight(self.bounds) - 40, NSWidth(self.bounds) - 36, 28))) hb = 3;
    if (hb != self.hoverBtn) { self.hoverBtn = hb; [self setNeedsDisplay:YES]; }
}
- (void)pickDir {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseFiles = NO; op.canChooseDirectories = YES; op.allowsMultipleSelection = NO;
    op.directoryURL = [NSURL fileURLWithPath:[FSRecSettings shared].dir];
    [op beginWithCompletionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK) {
            [FSRecSettings shared].dir = op.URLs.firstObject.path;
            [[FSRecSettings shared] save];
            [self setNeedsDisplay:YES];
            FSBarLog(@"[录屏] 保存目录 → %@", [FSRecSettings shared].dir);
        }
    }];
}
- (void)pickRegion {
    FSBarLog(@"[录屏] 打开区域选择");
    [self.panel orderOut:nil];
    FSRegionOverlayShow(^(CGRect cg, CGDirectDisplayID did) {
        FSRecSettings *s = [FSRecSettings shared];
        s.region = cg; s.regionDisplay = did; s.areaMode = 1;
        [s save];
        FSRegionOverlayClose();
        [self.panel orderFrontRegardless];
        [self setNeedsDisplay:YES];
    }, ^{
        FSRegionOverlayClose();
        [self.panel orderFrontRegardless];
    });
}
- (BOOL)canBecomeKeyView { return YES; }
- (void)keyDown:(NSEvent *)e { if (e.keyCode == 53) FSScreenRecCloseSettings(); }
@end

static NSPanel *g_settingsPanel = nil;

void FSScreenRecOpenSettings(void) {
    if (g_settingsPanel) { [g_settingsPanel orderFrontRegardless]; return; }
    CGFloat w = 320, h = 300;
    // 位置：鼠标所在屏居中（标准弹窗位；避免被桌面右上/右下的浮窗遮挡）
    NSPoint m = [NSEvent mouseLocation];
    NSScreen *sc = [NSScreen mainScreen];
    for (NSScreen *s in [NSScreen screens]) if (NSPointInRect(m, s.frame)) { sc = s; break; }
    NSRect vf = sc.visibleFrame;
    NSRect fr = NSMakeRect(NSMidX(vf) - w / 2.0, NSMidY(vf) - h / 2.0 + 20, w, h);
    NSPanel *p = [[NSPanel alloc] initWithContentRect:fr
        styleMask:NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered defer:NO];
    p.level = NSFloatingWindowLevel + 2;
    p.releasedWhenClosed = NO;
    p.opaque = NO;
    p.backgroundColor = [NSColor clearColor];
    p.ignoresMouseEvents = NO;
    p.movableByWindowBackground = YES;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    FSRecPanelView *v = [[FSRecPanelView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    v.panel = p;
    p.contentView = v;
    FSRecInstallGlass(p, 14);              // v 成为玻璃下的内容子视图
    [p makeKeyWindow];
    [p orderFrontRegardless];
    FSBarLog(@"[录屏] 设置小窗 frame=%@ visible=%d level=%ld screen=%@",
             NSStringFromRect(p.frame), (int)p.isVisible, (long)p.level,
             p.screen ? NSStringFromRect(p.screen.frame) : @"nil");
    g_settingsPanel = p;
    FSBarLog(@"[录屏] 设置小窗已打开（fps=%ld res=%ld%% area=%ld audio=%ld fmt=%ld）",
             (long)[FSRecSettings shared].fps, (long)[FSRecSettings shared].resScale,
             (long)[FSRecSettings shared].areaMode, (long)[FSRecSettings shared].audioMode,
             (long)[FSRecSettings shared].format);
}
void FSScreenRecCloseSettings(void) {
    [g_settingsPanel orderOut:nil];
    g_settingsPanel = nil;
    FSBarLog(@"[录屏] 设置小窗已关闭");
}

// ============ 录制引擎 ============
@interface FSRecEngine : NSObject <SCStreamDelegate, SCStreamOutput> {
    CMSampleBufferRef _pendingSys;   // 首帧系统音（建轨定格式用，手动 retain/release）
    CMSampleBufferRef _pendingMic;   // 首帧麦克风
}
@property (nonatomic) SCStream *stream;
@property (nonatomic) AVAssetWriter *writer;
@property (nonatomic) AVAssetWriterInput *vIn;
@property (nonatomic) AVAssetWriterInput *sysIn;
@property (nonatomic) AVAssetWriterInput *micIn;
@property (nonatomic) NSString *outPath;
@property (nonatomic) BOOL sessionStarted;
@property (nonatomic) size_t vw, vh;
@property (nonatomic) int droppedAudio;
@property (nonatomic) dispatch_queue_t q;
@property (nonatomic, copy) void (^onStarted)(void);
@property (nonatomic, copy) void (^onFinished)(NSString *path, NSError *err);
- (void)releasePending;
@end

@implementation FSRecEngine
- (instancetype)init {
    self = [super init];
    if (self) _q = dispatch_queue_create("frset.recorder.video", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)start {
    FSRecSettings *s = [FSRecSettings shared];
    // 输出文件（扩展名与 fileType 必须匹配，否则 -16345）
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    self.outPath = [s.dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"录屏-%@.%@", [df stringFromDate:[NSDate date]], s.ext]];
    self.sessionStarted = NO;
    self.droppedAudio = 0;
    FSBarLog(@"[录屏] 引擎启动 → %@", self.outPath);

    __weak FSRecEngine *weak = self;
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *e1) {
        if (e1 || !content || content.displays.count == 0) {
            FSBarLog(@"[录屏] 屏幕内容获取失败：%@", e1.localizedDescription ?: @"无显示器");
            [weak finishWithError:e1 ?: [NSError errorWithDomain:@"FSRec" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"无可用显示器"}]];
            return;
        }
        // 选屏：区域录制 → 区域所在屏；否则鼠标所在屏
        SCDisplay *disp = nil;
        NSPoint mouse = [NSEvent mouseLocation];
        CGDirectDisplayID want = 0;
        if (s.areaMode == 1 && !CGRectIsEmpty(s.region)) {
            want = s.regionDisplay;
            for (SCDisplay *d in content.displays) if (d.displayID == want) { disp = d; break; }
        }
        if (!disp) {
            for (SCDisplay *d in content.displays) {
                for (NSScreen *sc in [NSScreen screens]) {
                    CGDirectDisplayID did = ((NSNumber *)sc.deviceDescription[@"NSScreenNumber"]).unsignedIntValue;
                    if (did == d.displayID && NSPointInRect(mouse, sc.frame)) { disp = d; break; }
                }
                if (disp) break;
            }
        }
        if (!disp) disp = content.displays.firstObject;

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:disp
            excludingApplications:@[] exceptingWindows:@[]];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        double scale = s.resScale / 100.0;
        CGFloat bs = 1.0;
        for (NSScreen *sc in [NSScreen screens]) {
            CGDirectDisplayID did = ((NSNumber *)sc.deviceDescription[@"NSScreenNumber"]).unsignedIntValue;
            if (did == disp.displayID) { bs = sc.backingScaleFactor; break; }
        }
        CGRect src = CGRectMake(0, 0, disp.width, disp.height);
        if (s.areaMode == 1 && !CGRectIsEmpty(s.region)) {
            // region 是 CG 全局坐标 → 转到该 display 的 CG 坐标空间（左上原点）
            NSScreen *rsc = nil;
            for (NSScreen *sc in [NSScreen screens]) {
                CGDirectDisplayID did = ((NSNumber *)sc.deviceDescription[@"NSScreenNumber"]).unsignedIntValue;
                if (did == disp.displayID) { rsc = sc; break; }
            }
            CGFloat mainH = FSRecMainScreenH();
            // region（CG 全局左上原点）→ 该 display 局部坐标（左上原点）
            CGPoint regionTL = CGPointMake(s.region.origin.x, s.region.origin.y);
            CGPoint screenTL = CGPointMake(rsc.frame.origin.x, mainH - (rsc.frame.origin.y + rsc.frame.size.height));
            CGPoint local = CGPointMake(regionTL.x - screenTL.x, regionTL.y - screenTL.y);
            local.x = MAX(0, MIN(local.x, (CGFloat)disp.width));
            local.y = MAX(0, MIN(local.y, (CGFloat)disp.height));
            src = CGRectMake(local.x, local.y, s.region.size.width, s.region.size.height);
            src.size.width = MIN(src.size.width, (CGFloat)disp.width - src.origin.x);
            src.size.height = MIN(src.size.height, (CGFloat)disp.height - src.origin.y);
        }
        cfg.sourceRect = src;                      // 点坐标（12.3+）
        cfg.width  = (size_t)(src.size.width  * bs * scale);
        cfg.height = (size_t)(src.size.height * bs * scale);
        if (cfg.width < 480 || cfg.height < 320) {  // 下限保护
            cfg.width = MAX(cfg.width, 480); cfg.height = MAX(cfg.height, 320);
        }
        cfg.minimumFrameInterval = CMTimeMake(1, (int32_t)s.fps);
        cfg.pixelFormat = kCVPixelFormatType_32BGRA;
        cfg.showsCursor = YES;
        cfg.queueDepth = 5;
        cfg.colorSpaceName = kCGColorSpaceSRGB;
        // 音频
        if (@available(macOS 13.0, *)) { if (s.needSys) cfg.capturesAudio = YES; }
        if (@available(macOS 15.0, *)) { if (s.needMic) cfg.captureMicrophone = YES; }

        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:weak];
        NSError *e2 = nil;
        if (![stream addStreamOutput:weak type:SCStreamOutputTypeScreen sampleHandlerQueue:weak.q error:&e2]) {
            FSBarLog(@"[录屏] addStreamOutput(screen) 失败：%@", e2.localizedDescription);
            [weak finishWithError:e2]; return;
        }
        if (s.needSys) {
            if (![stream addStreamOutput:weak type:SCStreamOutputTypeAudio sampleHandlerQueue:weak.q error:&e2]) {
                FSBarLog(@"[录屏] addStreamOutput(audio) 失败：%@", e2.localizedDescription);
                [weak finishWithError:e2]; return;
            }
        }
        if (s.needMic) {
            if (![stream addStreamOutput:weak type:SCStreamOutputTypeMicrophone sampleHandlerQueue:weak.q error:&e2]) {
                FSBarLog(@"[录屏] addStreamOutput(microphone) 失败：%@", e2.localizedDescription);
                [weak finishWithError:e2]; return;
            }
        }
        weak.stream = stream;
        [stream startCaptureWithCompletionHandler:^(NSError *e3) {
            if (e3) { FSBarLog(@"[录屏] startCapture 失败：%@", e3.localizedDescription); [weak finishWithError:e3]; }
            else FSBarLog(@"[录屏] 已开始捕获（%zux%zu @%ldfps 音频模式=%ld）", weak.vw ? weak.vw : cfg.width,
                          weak.vh ? weak.vh : cfg.height, (long)s.fps, (long)s.audioMode);
        }];
    }];
}


- (void)releasePending {
    if (_pendingSys) { CFRelease(_pendingSys); _pendingSys = NULL; }
    if (_pendingMic) { CFRelease(_pendingMic); _pendingMic = NULL; }
}
- (void)dealloc { [self releasePending]; }

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (!CMSampleBufferDataIsReady(sb)) return;
    if (type == SCStreamOutputTypeScreen) {
        // 帧状态检查（丢弃 idle/dropped 帧；26 SDK 无 ValidValue 常量，用字符串键）
        CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
        if (atts && CFArrayGetCount(atts) > 0) {
            CFDictionaryRef a0 = CFArrayGetValueAtIndex(atts, 0);
            if (a0) {
                CFTypeRef st = CFDictionaryGetValue(a0, CFSTR("ValidValue"));
                if (st && CFGetTypeID(st) == CFBooleanGetTypeID() && !CFBooleanGetValue(st)) return;
            }
        }
        if (!self.sessionStarted) {
            CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
            CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fd);
            if (d.width < 16 || d.height < 16) return;
            self.vw = d.width; self.vh = d.height;
            NSError *werr = nil;
            self.writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:self.outPath]
                fileType:(AVFileType)[FSRecSettings shared].fileType error:&werr];
            if (!self.writer) {
                FSBarLog(@"[录屏] writer 创建失败：%@", werr.localizedDescription);
                [self finishWithError:werr]; return;
            }
            self.writer.movieFragmentInterval = CMTimeMake(10, 1);   // 10s 落片（崩溃时少丢数据）
            uint64_t br = (uint64_t)self.vw * self.vh * [FSRecSettings shared].fps * 0.08;
            br = MAX(br, 2000000); br = MIN(br, 40000000);
            NSDictionary *vs = @{
                AVVideoCodecKey: AVVideoCodecTypeH264,
                AVVideoWidthKey: @((NSInteger)self.vw),
                AVVideoHeightKey: @((NSInteger)self.vh),
                AVVideoCompressionPropertiesKey: @{
                    AVVideoAverageBitRateKey: @(br),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: @([FSRecSettings shared].fps),
                    AVVideoMaxKeyFrameIntervalKey: @([FSRecSettings shared].fps * 2),
                },
            };
            self.vIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vs];
            self.vIn.expectsMediaDataInRealTime = YES;
            if (![self.writer canAddInput:self.vIn]) {
                FSBarLog(@"[录屏] 视频轨无法添加");
                [self finishWithError:self.writer.error]; return;
            }
            [self.writer addInput:self.vIn];
            // 音频轨必须在 startWriting 之前建好（v47 踩坑：写会话开始后再 addInput 无效）。
            //   SCK 音频比首帧视频晚到（先出视频），缓冲法等不到 → 直接用固定 AAC 48k 立体声，
            //   AVAssetWriter 会自动把源（系统音 48k float 平面 / 麦克风异格式）重采样转换；
            //   -12737 只发生在两路写同一 input（开源实测），双 input 各 AAC 无此问题。
            // 方案 A（开源推荐）：系统音 / 麦克风各一条独立 AAC 轨 —— 绝不两源共轨
            //   （共轨会互相覆盖且触发 -12737 实测踩坑）
            NSDictionary *aac = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                                  AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2,
                                  AVEncoderBitRateKey: @128000};
            if ([FSRecSettings shared].needSys) {
                AVAssetWriterInput *ain = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:aac];
                ain.expectsMediaDataInRealTime = YES;
                if ([self.writer canAddInput:ain]) { [self.writer addInput:ain]; self.sysIn = ain;
                    FSBarLog(@"[录屏] 系统音轨已加入（AAC 48k 立体声，预建于 startWriting 前）"); }
                else FSBarLog(@"[录屏] 系统音轨无法添加");
            }
            if ([FSRecSettings shared].needMic) {
                AVAssetWriterInput *ain = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:aac];
                ain.expectsMediaDataInRealTime = YES;
                if ([self.writer canAddInput:ain]) { [self.writer addInput:ain]; self.micIn = ain;
                    FSBarLog(@"[录屏] 麦克风轨已加入（AAC 48k 立体声，预建于 startWriting 前）"); }
                else FSBarLog(@"[录屏] 麦克风轨无法添加");
            }
            if (![self.writer startWriting]) {
                FSBarLog(@"[录屏] startWriting 失败：%@", self.writer.error.localizedDescription);
                [self finishWithError:self.writer.error]; return;
            }
            CMTime vts = CMSampleBufferGetPresentationTimeStamp(sb);
            [self.writer startSessionAtSourceTime:vts];
            self.sessionStarted = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onStarted) self.onStarted();
            });
            FSBarLog(@"[录屏] writer 就绪（%zux%zu，~%llubps，音频轨 %d/%d）", self.vw, self.vh,
                     (unsigned long long)br, (int)(self.sysIn != nil), (int)(self.micIn != nil));
            // 补写缓冲的首个音频样本（早于视频入点的丢弃）
            if (self.sysIn && _pendingSys && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(_pendingSys), vts) >= 0) {
                [self.sysIn appendSampleBuffer:_pendingSys];
            }
            if (self.micIn && _pendingMic && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(_pendingMic), vts) >= 0) {
                [self.micIn appendSampleBuffer:_pendingMic];
            }
            [self releasePending];
        }
        if (self.writer.status == AVAssetWriterStatusWriting && self.vIn.isReadyForMoreMediaData) {
            if (![self.vIn appendSampleBuffer:sb]) {
                FSBarLog(@"[录屏] 追加视频帧失败：%@", self.writer.error.localizedDescription ?: @"?");
            }
        }
        return;
    }
    // 音频：视频帧未到时缓冲首帧（建轨定格式）；session 后直接追加
    static NSInteger sAudioSeen = 0, sMicSeen = 0;
    if (type == SCStreamOutputTypeAudio) sAudioSeen++;
    if (type == SCStreamOutputTypeMicrophone) sMicSeen++;
    if ((sAudioSeen + sMicSeen) % 200 == 1)
        FSBarLog(@"[录屏] 音频样本：系统 %ld / 麦克 %ld（session=%d sysIn=%d micIn=%d）",
                 (long)sAudioSeen, (long)sMicSeen, (int)self.sessionStarted,
                 (int)(self.sysIn != nil), (int)(self.micIn != nil));
    if (!self.sessionStarted) {
        if (type == SCStreamOutputTypeAudio && !_pendingSys) {
            CFRetain(sb); _pendingSys = sb;
        } else if (type == SCStreamOutputTypeMicrophone && !_pendingMic) {
            CFRetain(sb); _pendingMic = sb;
        }
        return;
    }
    static NSInteger sAudioFail = 0;
    if (type == SCStreamOutputTypeAudio) {
        if (self.sysIn && self.sysIn.isReadyForMoreMediaData && ![self.sysIn appendSampleBuffer:sb] && (sAudioFail++ % 100) == 0)
            FSBarLog(@"[录屏] 系统音追加失败：%@", self.writer.error.localizedDescription ?: @"?");
    } else if (type == SCStreamOutputTypeMicrophone) {
        if (self.micIn && self.micIn.isReadyForMoreMediaData && ![self.micIn appendSampleBuffer:sb] && (sAudioFail++ % 100) == 0)
            FSBarLog(@"[录屏] 麦克风追加失败：%@", self.writer.error.localizedDescription ?: @"?");
    }
}

- (void)stop {
    FSBarLog(@"[录屏] 停止中…（丢弃早到音频 %d 帧）", self.droppedAudio);
    __weak FSRecEngine *weak = self;
    [self.stream stopCaptureWithCompletionHandler:^(NSError *e) {
        if (e) FSBarLog(@"[录屏] stopCapture：%@", e.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weak.writer.status == AVAssetWriterStatusWriting) {
                [weak.vIn markAsFinished];
                if (weak.sysIn) [weak.sysIn markAsFinished];
                if (weak.micIn) [weak.micIn markAsFinished];
                [weak.writer finishWritingWithCompletionHandler:^{
                    NSError *ferr = weak.writer.error;
                    if (ferr) FSBarLog(@"[录屏] 收尾失败：%@", ferr.localizedDescription);
                    // 不在收尾里自动弹 Finder：录制是高频操作，每次都跳窗口很吵，
                    // 而且 selectFile 会抢焦点、把后面的完成回调拖住。
                    // 改成「完成提示面板」里手动点「在 Finder 中显示」。
                    NSString *finalPath = ferr ? nil : weak.outPath;

                    // GIF：mov 只是中间产物，转完立刻删掉，只留 GIF
                    if (finalPath && [FSRecSettings shared].isGIF) {
                        NSString *moviePath = finalPath;
                        NSString *gifPath = [[moviePath stringByDeletingPathExtension]
                                             stringByAppendingPathExtension:@"gif"];
                        NSInteger fps = [FSRecSettings shared].fps;
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                            NSString *converted = FSRecConvertMovieToGIF(moviePath, gifPath, fps, 720);
                            if (converted) {
                                [[NSFileManager defaultManager] removeItemAtPath:moviePath error:NULL];
                                FSBarLog(@"[录屏] 已转 GIF → %@", converted);
                            } else {
                                FSBarLog(@"[录屏] GIF 转换失败，保留 mov 中间文件");
                            }
                            NSString *result = converted ?: moviePath;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (weak.onFinished) weak.onFinished(result, ferr);
                            });
                        });
                        return;
                    }

                    if (weak.onFinished) weak.onFinished(finalPath, ferr);
                }];
            } else {
                if (weak.onFinished) weak.onFinished(nil, weak.writer.error);
            }
        });
    }];
}

- (void)finishWithError:(NSError *)err {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onFinished) self.onFinished(nil, err);
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (error) FSBarLog(@"[录屏] 流中断：%@", error.localizedDescription);
    [self finishWithError:error];
}
@end

// ============ 对外接口 ============
static FSRecEngine *g_engine = nil;
static BOOL g_starting = NO;

// 供探针离屏渲染用的视图取值（frset_stats_inject.m 的 FSRenderView 用）
NSView *FSScreenRecDebugPanelView(void) { return g_settingsPanel.contentView; }
NSView *FSScreenRecDebugBarView(void) { return g_barWin.contentView; }


// ============ 录制完成提示（参考 QuickRecorder 的完成反馈） ============
// 之前录完只写日志，用户不知道文件在哪、录成功没有。这里给一个 5 秒自动消失的
// 小面板：图标 + 「录屏已保存」+ 文件名 + [在 Finder 中显示] [打开]。
static NSPanel *g_donePanel = nil;
static NSString *g_donePath = nil;
static void FSScreenRecCloseDone(void);   // 前向声明：按钮点击里要用
static void FSRecShowDonePanel(NSString *path, NSError *err);   // v109 前向声明：Stop 超时兜底要用

@interface FSRecDoneView : NSView
@property (nonatomic) NSInteger hoverBtn;   // 0 无 1 finder 2 打开
@end

@implementation FSRecDoneView
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (NSRect)finderRect {
    CGFloat w = NSWidth(self.bounds);
    return NSMakeRect(18, NSHeight(self.bounds) - 34, (w - 44) / 2.0, 22);
}
- (NSRect)openRect {
    CGFloat w = NSWidth(self.bounds);
    return NSMakeRect(18 + (w - 44) / 2.0 + 8, NSHeight(self.bounds) - 34, (w - 44) / 2.0, 22);
}

- (void)drawRect:(NSRect)dirty {
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    [[[NSColor controlBackgroundColor] colorWithAlphaComponent:0.9] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:12 yRadius:12] fill];
    [[[NSColor separatorColor] colorWithAlphaComponent:0.5] setStroke];
    NSBezierPath *bd = [NSBezierPath bezierPathWithRoundedRect:r xRadius:12 yRadius:12];
    bd.lineWidth = 1; [bd stroke];

    // 图标（绿色对勾圆）
    [[NSColor colorWithSRGBRed:0.30 green:0.72 blue:0.38 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(16, NSHeight(self.bounds) - 40, 18, 18)] fill];
    [[NSColor whiteColor] setStroke];
    NSBezierPath *ck = [NSBezierPath bezierPath];
    [ck moveToPoint:NSMakePoint(20, NSHeight(self.bounds) - 31.5)];
    [ck lineToPoint:NSMakePoint(23.5, NSHeight(self.bounds) - 35)];
    [ck lineToPoint:NSMakePoint(30, NSHeight(self.bounds) - 27.5)];
    ck.lineWidth = 1.8; ck.lineCapStyle = NSLineCapStyleRound; [ck stroke];

    NSDictionary *ta = @{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                         NSForegroundColorAttributeName: NSColor.labelColor};
    // path 为 nil 时是「保存中」态（收尾还没回来）
    NSString *title = g_donePath.length ? @"录屏已保存" : @"正在保存录屏…";
    [title drawAtPoint:NSMakePoint(42, NSHeight(self.bounds) - 39) withAttributes:ta];

    NSDictionary *na = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5],
                         NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    NSString *name = g_donePath.lastPathComponent ?: @"";
    if (name.length > 34) name = [[name substringToIndex:31] stringByAppendingString:@"…"];
    [name drawAtPoint:NSMakePoint(42, NSHeight(self.bounds) - 53) withAttributes:na];

    // 保存中态没有按钮（收尾完成后再给操作）
    if (!g_donePath.length) return;
    NSArray *titles = @[@"在 Finder 中显示", @"打开"];
    for (NSInteger i = 0; i < 2; i++) {
        NSRect br = i == 0 ? [self finderRect] : [self openRect];
        BOOL hot = self.hoverBtn == i + 1;
        [[[NSColor separatorColor] colorWithAlphaComponent:hot ? 0.45 : 0.25] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:br xRadius:6 yRadius:6] fill];
        NSDictionary *ba = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName: NSColor.labelColor};
        NSSize bs = [titles[i] sizeWithAttributes:ba];
        [titles[i] drawAtPoint:NSMakePoint(NSMidX(br) - bs.width / 2.0, NSMidY(br) - bs.height / 2.0)
                withAttributes:ba];
    }
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (NSPointInRect(p, [self finderRect])) {
        if (g_donePath) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:g_donePath]]];
        FSScreenRecCloseDone();
    } else if (NSPointInRect(p, [self openRect])) {
        if (g_donePath) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:g_donePath]];
        FSScreenRecCloseDone();
    }
}
- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger h = NSPointInRect(p, [self finderRect]) ? 1 : (NSPointInRect(p, [self openRect]) ? 2 : 0);
    if (h != self.hoverBtn) { self.hoverBtn = h; [self setNeedsDisplay:YES]; }
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:area];
}
@end

static void FSScreenRecCloseDone(void) {
    [g_donePanel orderOut:nil];
    g_donePanel = nil;
}

/// 录制结束后弹完成提示（成功显示文件名，失败显示原因）
static void FSRecShowDonePanel(NSString *path, NSError *err) {
    FSScreenRecCloseDone();
    g_donePath = path;
    // v109（2026-10-21 用户：「保存之后要有提示说在哪里」）：广播给 Swift 侧
    // 弹 Toast（与截图「已保存」同款提示）；完成面板本身继续走原逻辑。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FrsetScreenRecDidSave"
                                                        object:nil
                                                      userInfo:@{@"path": path ?: @""}];
    CGFloat w = 300, h = 96;
    NSScreen *sc = [NSScreen mainScreen];
    NSRect vf = sc.visibleFrame;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(NSMidX(vf) - w / 2.0, NSMinY(vf) + 60, w, h)
        styleMask:NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered defer:NO];
    p.level = NSFloatingWindowLevel + 4;
    p.releasedWhenClosed = NO;
    p.opaque = NO;
    p.backgroundColor = [NSColor clearColor];
    p.ignoresMouseEvents = NO;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    FSRecDoneView *v = [[FSRecDoneView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    p.contentView = v;
    [p orderFrontRegardless];
    g_donePanel = p;
    // 完成态 5 秒后自动收起；「保存中」态不自动收（等收尾结果来替换）
    if (path.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FSScreenRecCloseDone();
        });
    }
    FSBarLog(@"[录屏] 完成提示已显示 path=%@ err=%@", path ?: @"-", err.localizedDescription ?: @"-");
}

void FSScreenRecBeginFromSettings(void) {
    FSRecSettings *s = [FSRecSettings shared];
    if (s.needMic) {
        if (![[AVCaptureDevice class] respondsToSelector:@selector(requestAccessForMediaType:completionHandler:)]) {
            FSBarLog(@"[录屏] 麦克风不可用（系统过老），降级为无音频");
            s.audioMode = 0; [s save];
        } else {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) { FSBarLog(@"[录屏] 麦克风权限被拒绝，按「系统音」继续"); [FSRecSettings shared].audioMode = (s.needSys ? 1 : 0); [[FSRecSettings shared] save]; }
                    FSScreenRecBeginFromSettings();
                });
            }];
            return;
        }
    }
    if (g_engine || g_starting) { FSBarLog(@"[录屏] 已在进行中"); return; }
    // 录制期间阻止 App 被系统自动终止（无窗口时 macOS 会回收，导致录到一半断掉）
    [[NSProcessInfo processInfo] disableAutomaticTermination:@"frset.screenrecording"];
    g_starting = YES;
    g_engine = [[FSRecEngine alloc] init];
    g_engine.onStarted = ^{
        g_starting = NO;
        FSScreenRecCloseSettings();
        FSRecBarShow();
    };
    g_engine.onFinished = ^(NSString *path, NSError *err) {
        FSRecEngine *finished = g_engine;
        g_engine = nil;
        g_starting = NO;
        (void)finished;
        // 录制结束，恢复系统的自动终止行为
        [[NSProcessInfo processInfo] enableAutomaticTermination:@"frset.screenrecording"];
        FSRecBarHide();
        if (path) FSBarLog(@"[录屏] 完成 → %@", path);
        else FSBarLog(@"[录屏] 失败：%@", err.localizedDescription ?: @"未知");
        // 用户可见反馈：成功给「在 Finder 中显示 / 打开」，失败给出原因
        FSRecShowDonePanel(path, err);
    };
    FSBarLog(@"[录屏] 开始（fps=%ld res=%ld%% 区域=%ld 音频=%ld 格式=%ld）",
             (long)s.fps, (long)s.resScale, (long)s.areaMode, (long)s.audioMode, (long)s.format);
    [g_engine start];
}
void FSScreenRecStop(void) {
    // v109：收尾回调偶发不回来（收尾回调不回来 → 完成面板卡在「正在保存」、
    // 用户看不到保存提示）。8s 兜底：扫描保存目录取最新产物补弹完成面板。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_donePath != nil) return;
        NSString *dir = [FSRecSettings shared].dir ?: NSHomeDirectory();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *best = nil; NSDate *bestDate = nil;
        for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            NSString *ext = name.pathExtension.lowercaseString;
            if (!([ext isEqualToString:@"mov"] || [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"gif"])) continue;
            NSString *fp = [dir stringByAppendingPathComponent:name];
            NSDate *d = [fm attributesOfItemAtPath:fp error:nil].fileModificationDate;
            if (d && [d timeIntervalSinceNow] > -120 && (!bestDate || [d compare:bestDate] == NSOrderedDescending)) {
                bestDate = d; best = fp;
            }
        }
        if (best) {
            FSBarLog(@"[录屏] 收尾回调超时，兜底取最新产物：%@", best);
            FSRecShowDonePanel(best, nil);
        } else {
            FSBarLog(@"[录屏] 收尾回调超时且未找到产物");
        }
    });
    // 先给「正在保存」反馈，再收尾：收尾回调偶发不回来（或进程被回收）时，
    // 用户至少知道已经点了停止、文件在写。
    FSRecShowDonePanel(nil, nil);
    [g_engine stop];
}
BOOL FSScreenRecIsRunning(void) { return g_engine != nil; }

