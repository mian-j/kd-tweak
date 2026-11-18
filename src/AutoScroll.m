//
//  AutoScroll.m  —  可达漫画 1.5.2 自动滚屏外挂（v3）
//
//  v1 的错：整窗铺满 + hitTest 返回 nil，全 App 点不动。
//  v2 的错：只用「面积最大的可滚动 UIScrollView」猜目标，猜错了就永远不动，
//          而且没有任何现场信息可看。
//
//  v3 的做法：
//    1) 直接拿 ReaderController 实例，从它的 collectionView 实例变量取到
//       真正承载页面的 UICollectionView（_TtC9kedamanga25ReaderPagesCollectionView），
//       不再靠"猜"。
//    2) 两种驱动：连续滚动（条漫/自由滚动模式）与整页推进（分页模式），
//       按 isPagingEnabled 自动选；连续模式一旦检测到吸附回弹，自动切整页。
//    3) 常驻诊断面板：目标类名、contentSize、contentOffset、实测 Δ/s、帧数、吸附次数、
//       最近日志。出问题一张截图就能定位。
//    4) 窗口只有「按钮 + 面板」那么大，绝不挡住 App 的其他触摸。
//
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - 日志

static NSMutableArray<NSString *> *gLines = nil;

static void KLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gLines) gLines = [NSMutableArray array];
    [gLines addObject:m];
    while (gLines.count > 5) [gLines removeObjectAtIndex:0];
    NSLog(@"[KDAuto] %@", m);
}

static NSString *KLastLines(void) {
    return gLines.count ? [gLines componentsJoinedByString:@"\n"] : @"—";
}

#pragma mark - 运行时工具

static NSArray<UIWindow *> *KWindows(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        if (sc.activationState != UISceneActivationStateForegroundActive) continue;
        [a addObjectsFromArray:((UIWindowScene *)sc).windows];
    }
    if (a.count == 0) {
        [a addObjectsFromArray:UIApplication.sharedApplication.windows];
    }
    return a;
}

static UIWindow *KKeyWindow(void) {
    for (UIWindow *w in KWindows()) {
        if (w.isKeyWindow) return w;
    }
    for (UIWindow *w in KWindows()) {
        if (!w.hidden && w.alpha > 0.1) return w;
    }
    return nil;
}

/// 读实例变量（Swift 存储属性在 ObjC 运行时里就是普通 ivar，名字不带下划线）
static id KGetIvar(id obj, const char *name) {
    if (!obj) return nil;
    Class c = object_getClass(obj);
    while (c) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) {
            const char *t = ivar_getTypeEncoding(iv);
            if (!t || t[0] != '@') return nil;
            ptrdiff_t off = ivar_getOffset(iv);
            char *base = (char *)(__bridge void *)obj;
            id __unsafe_unretained v = *(id __unsafe_unretained *)(base + off);
            return v;
        }
        c = class_getSuperclass(c);
    }
    return nil;
}

static UIViewController *KFindVC(UIViewController *vc, NSString *kw, int depth) {
    if (!vc || depth > 24) return nil;
    if ([NSStringFromClass(vc.class) containsString:kw]) return vc;
    UIViewController *r = KFindVC(vc.presentedViewController, kw, depth + 1);
    if (r) return r;
    for (UIViewController *c in vc.children) {
        r = KFindVC(c, kw, depth + 1);
        if (r) return r;
    }
    return nil;
}

static UIView *KFindView(UIView *root, NSString *kw, int depth) {
    if (!root || depth > 32) return nil;
    if ([NSStringFromClass(root.class) containsString:kw]) return root;
    for (UIView *s in root.subviews) {
        UIView *r = KFindView(s, kw, depth + 1);
        if (r) return r;
    }
    return nil;
}

#pragma mark - 核心

typedef NS_ENUM(NSInteger, KMode) {
    KModeNone = 0,
    KModeContinuous = 1,
    KModePage = 2,
};

static NSString *const kSpeedKey = @"KD3.speed";
static NSString *const kPosKey   = @"KD3.pos";

@interface KDScroll : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIView *ball;
@property (nonatomic, strong) UILabel *ballLabel;
@property (nonatomic, strong) UILabel *panel;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSTimer *panelTimer;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL panelOn;
@property (nonatomic, assign) CGFloat speed;          // pt / 秒，1× = 60
@property (nonatomic, assign) CGPoint ballCenter;
@property (nonatomic, weak) UIViewController *reader;
@property (nonatomic, weak) UIScrollView *target;
@property (nonatomic, assign) KMode mode;
@property (nonatomic, assign) BOOL vertical;
@property (nonatomic, assign) BOOL paging;
@property (nonatomic, assign) CGFloat lastOff;
@property (nonatomic, assign) CFTimeInterval lastTick;
@property (nonatomic, assign) CFTimeInterval nextPageAt;
@property (nonatomic, assign) CFTimeInterval measureAt;
@property (nonatomic, assign) CGFloat measureBase;
@property (nonatomic, assign) CGFloat measuredSpeed;
@property (nonatomic, assign) NSInteger frames;
@property (nonatomic, assign) NSInteger snaps;
@property (nonatomic, assign) NSInteger pageCount;
@property (nonatomic, assign) CFTimeInterval endSince;
@end

@implementation KDScroll

+ (instancetype)shared {
    static KDScroll *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [KDScroll new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        CGFloat v = [[NSUserDefaults standardUserDefaults] doubleForKey:kSpeedKey];
        _speed = v > 5 ? v : 60.0;
        NSDictionary *pos = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kPosKey];
        _ballCenter = CGPointZero;
        if (pos) _ballCenter = CGPointMake([pos[@"x"] doubleValue], [pos[@"y"] doubleValue]);
    }
    return self;
}

#pragma mark 安装

- (void)install {
    if (self.win) return;
    UIWindow *base = KKeyWindow();
    if (!base) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }

    CGSize scr = UIScreen.mainScreen.bounds.size;
    if (self.ballCenter.x <= 0 && self.ballCenter.y <= 0) {
        self.ballCenter = CGPointMake(scr.width - 46, 150);
    }

    UIWindow *w = [[UIWindow alloc] initWithWindowScene:base.windowScene];
    w.windowLevel = UIWindowLevelAlert - 1.0;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [UIViewController new];
    w.hidden = NO;
    self.win = w;

    UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    ball.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22];
    ball.layer.cornerRadius = 11;
    ball.layer.borderWidth = 1.0;
    ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    ball.userInteractionEnabled = YES;
    self.ball = ball;

    UILabel *lab = [[UILabel alloc] initWithFrame:ball.bounds];
    lab.textAlignment = NSTextAlignmentCenter;
    lab.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    lab.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
    lab.userInteractionEnabled = NO;
    [ball addSubview:lab];
    self.ballLabel = lab;

    UILabel *panel = [[UILabel alloc] initWithFrame:CGRectZero];
    panel.numberOfLines = 0;
    panel.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    panel.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    panel.layer.cornerRadius = 6;
    panel.clipsToBounds = YES;
    panel.userInteractionEnabled = NO;
    panel.hidden = YES;
    [w.rootViewController.view addSubview:panel];
    self.panel = panel;

    UITapGestureRecognizer *tap1 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
    UITapGestureRecognizer *tap2 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap)];
    tap2.numberOfTapsRequired = 2;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.4;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    for (UIGestureRecognizer *g in @[tap1, tap2, lp, pan]) {
        g.delegate = self;
        [ball addGestureRecognizer:g];
    }
    [tap1 requireGestureRecognizerToFail:tap2];
    [tap1 requireGestureRecognizerToFail:lp];

    [w.rootViewController.view addSubview:ball];

    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    [self layoutUI];
    KLog(@"v3 就绪");
}

#pragma mark 布局

- (NSString *)speedText {
    CGFloat x = self.speed / 60.0;
    return fabs(x - round(x)) < 0.05 ? [NSString stringWithFormat:@"%.0f×", x]
                                    : [NSString stringWithFormat:@"%.1f×", x];
}

- (void)layoutUI {
    if (!self.win) return;
    CGSize scr = UIScreen.mainScreen.bounds.size;
    CGFloat d = self.expanded ? 46 : 22;

    CGPoint c = self.ballCenter;
    c.x = MIN(MAX(c.x, d / 2 + 6), scr.width - d / 2 - 6);
    c.y = MIN(MAX(c.y, d / 2 + 46), scr.height - d / 2 - 6);
    self.ballCenter = c;

    CGRect ballRect = CGRectMake(c.x - d / 2, c.y - d / 2, d, d);
    CGRect panRect = CGRectZero;
    if (self.panelOn) {
        CGFloat pw = MIN(320, scr.width - 16);
        self.panel.text = [self panelText];
        CGSize fit = [self.panel sizeThatFits:CGSizeMake(pw - 14, CGFLOAT_MAX)];
        CGFloat ph = ceil(fit.height) + 14;
        CGFloat py = ballRect.origin.y - ph - 8;
        if (py < 24) py = CGRectGetMaxY(ballRect) + 8;
        CGFloat px = MIN(MAX(c.x - pw / 2, 8), scr.width - pw - 8);
        panRect = CGRectMake(px, py, pw, ph);
    }

    CGRect u = self.panelOn ? CGRectUnion(ballRect, panRect) : ballRect;
    u = CGRectInset(u, -2, -2);
    self.win.frame = u;

    self.ball.frame = CGRectOffset(ballRect, -u.origin.x, -u.origin.y);
    self.ball.layer.cornerRadius = d / 2;
    self.ballLabel.frame = self.ball.bounds;
    self.ballLabel.font = [UIFont systemFontOfSize:(self.expanded ? 12 : 9) weight:UIFontWeightSemibold];

    if (self.panelOn) {
        self.panel.hidden = NO;
        self.panel.frame = CGRectOffset(panRect, -u.origin.x, -u.origin.y);
    } else {
        self.panel.hidden = YES;
    }
    [self updateBallLook];
}

- (void)updateBallLook {
    if (!self.expanded) {
        self.ballLabel.text = @"";
        self.ball.backgroundColor = [UIColor colorWithWhite:0 alpha:(self.running ? 0.30 : 0.20)];
        self.ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:(self.running ? 0.55 : 0.22)].CGColor;
        return;
    }
    if (self.running && self.mode != KModeNone) {
        self.ballLabel.text = [NSString stringWithFormat:@"%@▸", [self speedText]];
        self.ball.backgroundColor = [UIColor colorWithRed:0.98 green:0.62 blue:0.30 alpha:0.92];
        self.ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
    } else if (self.running) {
        self.ballLabel.text = @"?";
        self.ball.backgroundColor = [UIColor colorWithRed:0.85 green:0.62 blue:0.10 alpha:0.92];
        self.ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    } else {
        self.ballLabel.text = @"播";
        self.ball.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    }
}

- (NSString *)modeText {
    switch (self.mode) {
        case KModeContinuous: return self.vertical ? @"连续·纵向" : @"连续·横向";
        case KModePage:       return @"整页推进";
        default:              return @"未锁定目标";
    }
}

- (NSString *)panelText {
    NSMutableString *s = [NSMutableString string];
    UIScrollView *t = self.target;
    if (t) {
        [s appendFormat:@"%@  %@  paging=%d\n", [self modeText],
            NSStringFromClass(t.class), t.isPagingEnabled];
        [s appendFormat:@"content %.0f×%.0f   view %.0f×%.0f\n",
            t.contentSize.width, t.contentSize.height, t.bounds.size.width, t.bounds.size.height];
        [s appendFormat:@"off %.1f   %.0f pt/s   实测 %.0f pt/s\n",
            self.vertical ? t.contentOffset.y : t.contentOffset.x, self.speed, self.measuredSpeed];
        [s appendFormat:@"帧 %ld  切页 %ld  吸附 %ld",
            (long)self.frames, (long)self.pageCount, (long)self.snaps];
    } else {
        [s appendString:@"未找到可滚动目标\n"];
        [s appendFormat:@"reader=%@\n", self.reader ? NSStringFromClass(self.reader.class) : @"nil"];
        [s appendFormat:@"帧 %ld", (long)self.frames];
    }
    [s appendFormat:@"\n———\n%@", KLastLines()];
    return s;
}

- (void)refreshPanel {
    if (self.panelOn) [self layoutUI];
}

- (void)showPanelFor:(NSTimeInterval)sec {
    self.panelOn = YES;
    [self layoutUI];
    [self.panelTimer invalidate];
    self.panelTimer = [NSTimer scheduledTimerWithTimeInterval:sec target:self
                                                    selector:@selector(hidePanel)
                                                    userInfo:nil repeats:NO];
}

- (void)hidePanel {
    self.panelOn = NO;
    [self layoutUI];
}

#pragma mark 手势

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}

- (void)onTap {
    if (!self.expanded) {
        self.expanded = YES;
        [self layoutUI];
    }
    if (self.running) {
        self.running = NO;
        KLog(@"停止");
        [self updateBallLook];
        [self showPanelFor:4];
        return;
    }
    [self probe];
    if (!self.target) {
        [self showPanelFor:8];
        return;
    }
    self.running = YES;
    self.lastTick = 0;
    self.nextPageAt = 0;
    self.measureAt = 0;
    self.measuredSpeed = 0;
    self.snaps = 0;
    self.frames = 0;
    self.endSince = 0;
    KLog(@"开始 %@ %@", [self modeText], [self speedText]);
    [self updateBallLook];
    [self showPanelFor:6];
}

- (void)onDoubleTap {
    if (self.panelOn) {
        [self.panelTimer invalidate];
        [self hidePanel];
    } else {
        [self probe];
        [self showPanelFor:12];
    }
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!self.expanded) {
        self.expanded = YES;
        [self layoutUI];
    }
    NSArray *vals = @[@30, @60, @120, @210];
    NSUInteger idx = 1;
    for (NSUInteger i = 0; i < vals.count; i++) {
        if (fabs([vals[i] doubleValue] - self.speed) < 5) { idx = i; break; }
    }
    idx = (idx + 1) % vals.count;
    self.speed = [vals[idx] doubleValue];
    [[NSUserDefaults standardUserDefaults] setDouble:self.speed forKey:kSpeedKey];
    KLog(@"速度 %@", [self speedText]);
    [self updateBallLook];
    [self showPanelFor:4];

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:nil];
    [g setTranslation:CGPointZero inView:nil];
    self.ballCenter = CGPointMake(self.ballCenter.x + t.x, self.ballCenter.y + t.y);
    [self layoutUI];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [[NSUserDefaults standardUserDefaults] setObject:@{@"x": @(self.ballCenter.x),
                                                           @"y": @(self.ballCenter.y)}
                                                  forKey:kPosKey];
    }
}

#pragma mark 目标探测

- (void)probe {
    self.target = nil;
    self.mode = KModeNone;
    self.reader = nil;

    UIViewController *found = nil;
    for (UIWindow *w in KWindows()) {
        found = KFindVC(w.rootViewController, @"ReaderController", 0);
        if (found) break;
    }

    if (found) {
        self.reader = found;
        id cv = KGetIvar(found, "collectionView");
        if (![cv isKindOfClass:UIScrollView.class]) {
            cv = KFindView(found.view, @"ReaderPagesCollectionView", 0);
        }
        if (![cv isKindOfClass:UIScrollView.class]) {
            cv = [self bestScroll:found.view];
        }
        if ([cv isKindOfClass:UIScrollView.class]) {
            [self adopt:cv];
            return;
        }
        KLog(@"ReaderController 里没有 collectionView");
        return;
    }

    for (UIWindow *w in KWindows()) {
        UIView *v = KFindView(w, @"ReaderPagesCollectionView", 0);
        if ([v isKindOfClass:UIScrollView.class]) {
            [self adopt:(UIScrollView *)v];
            return;
        }
    }
    KLog(@"不在阅读界面");
}

- (UIScrollView *)bestScroll:(UIView *)root {
    __block UIScrollView *best = nil;
    __block CGFloat bestScore = 0;
    __block void (^walk)(UIView *, int);
    walk = ^(UIView *v, int d) {
        if (!v || d > 30) return;
        if ([v isKindOfClass:UIScrollView.class]) {
            UIScrollView *s = (UIScrollView *)v;
            CGFloat dy = s.contentSize.height - s.bounds.size.height;
            CGFloat dx = s.contentSize.width - s.bounds.size.width;
            CGFloat score = MAX(dy, dx);
            if (s.window && !s.hidden && score > 8 && score > bestScore) {
                bestScore = score;
                best = s;
            }
        }
        for (UIView *sub in v.subviews) walk(sub, d + 1);
    };
    walk(root, 0);
    return best;
}

- (void)adopt:(UIScrollView *)s {
    self.target = s;
    CGFloat dy = s.contentSize.height + s.adjustedContentInset.bottom - s.bounds.size.height;
    CGFloat dx = s.contentSize.width + s.adjustedContentInset.right - s.bounds.size.width;
    self.vertical = dy >= dx;
    self.paging = s.isPagingEnabled;
    self.lastOff = self.vertical ? s.contentOffset.y : s.contentOffset.x;

    CGFloat ext = self.vertical ? dy : dx;
    if (ext <= 8) {
        self.mode = KModeNone;
        KLog(@"%@ 不可滚 ext=%.0f", NSStringFromClass(s.class), ext);
        return;
    }
    self.mode = self.paging ? KModePage : KModeContinuous;
    KLog(@"锁定 %@ %@", NSStringFromClass(s.class), [self modeText]);
}

- (void)switchToPage:(NSString *)why {
    if (self.mode == KModePage) return;
    self.mode = KModePage;
    self.nextPageAt = 0;
    self.snaps++;
    KLog(@"%@ → 整页推进", why);
    [self updateBallLook];
    [self refreshPanel];
}

#pragma mark 主循环

- (void)tick {
    if (!self.running) return;

    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = self.lastTick > 0 ? (now - self.lastTick) : 0;
    self.lastTick = now;
    if (dt <= 0 || dt > 0.2) return;

    if (!self.target || self.target.window == nil) {
        [self probe];
        if (!self.target) { [self updateBallLook]; return; }
    }

    UIScrollView *s = self.target;
    if (self.mode == KModeContinuous) {
        [self stepContinuous:s dt:dt now:now];
    } else if (self.mode == KModePage) {
        [self stepPage:s now:now];
    } else {
        [self probe];
    }

    self.frames++;
    if (self.frames % 12 == 0) {
        [self updateBallLook];
        [self refreshPanel];
    }
}

- (void)stepContinuous:(UIScrollView *)s dt:(CGFloat)dt now:(CFTimeInterval)now {
    UIEdgeInsets in = s.adjustedContentInset;
    CGPoint off = s.contentOffset;
    CGFloat step = self.speed * dt;

    if (self.vertical) {
        CGFloat maxY = s.contentSize.height + in.bottom - s.bounds.size.height;
        if (maxY <= 8) { [self switchToPage:@"纵向到底"]; return; }
        if (off.y < self.lastOff - 40) {
            // App 把 offset 拉回去了：多半是分页吸附
            [self switchToPage:@"检测到回弹"];
            return;
        }
        CGFloat y = off.y + step;
        if (y >= maxY) {
            y = maxY;
            [self noteEnd:now];
        } else {
            self.endSince = 0;
        }
        s.contentOffset = CGPointMake(off.x, y);
        self.lastOff = y;
    } else {
        CGFloat maxX = s.contentSize.width + in.right - s.bounds.size.width;
        if (maxX <= 8) { [self switchToPage:@"横向到底"]; return; }
        if (off.x < self.lastOff - 40) {
            [self switchToPage:@"检测到回弹"];
            return;
        }
        CGFloat x = off.x + step;
        if (x >= maxX) {
            x = maxX;
            [self noteEnd:now];
        } else {
            self.endSince = 0;
        }
        s.contentOffset = CGPointMake(x, off.y);
        self.lastOff = x;
    }

    // 实测速度（每 0.6 秒算一次，用来证明"到底动没动"）
    if (now > self.measureAt + 0.6) {
        CGFloat cur = self.vertical ? s.contentOffset.y : s.contentOffset.x;
        if (self.measureAt > 0) {
            self.measuredSpeed = (cur - self.measureBase) / (now - self.measureAt);
        }
        self.measureBase = cur;
        self.measureAt = now;
    }
}

- (void)stepPage:(UIScrollView *)s now:(CFTimeInterval)now {
    if (now < self.nextPageAt) return;
    CGFloat interval = MAX(0.5, 3.0 * 60.0 / MAX(self.speed, 1.0));
    self.nextPageAt = now + interval;

    if (![s isKindOfClass:UICollectionView.class]) {
        // 普通 scroll view：一屏一屏推
        CGPoint off = s.contentOffset;
        if (self.vertical) {
            CGFloat maxY = s.contentSize.height - s.bounds.size.height;
            if (off.y >= maxY - 1) { [self noteEnd:now]; return; }
            off.y = MIN(maxY, off.y + s.bounds.size.height * 0.96);
        } else {
            CGFloat maxX = s.contentSize.width - s.bounds.size.width;
            if (off.x >= maxX - 1) { [self noteEnd:now]; return; }
            off.x = MIN(maxX, off.x + s.bounds.size.width * 0.96);
        }
        self.pageCount++;
        [s setContentOffset:off animated:YES];
        return;
    }

    UICollectionView *cv = (UICollectionView *)s;
    NSArray<NSIndexPath *> *ips = cv.indexPathsForVisibleItems;
    if (ips.count == 0) return;

    // 取离屏幕中心最近的那一项，避免把预加载的相邻页当成当前页
    CGRect vis = CGRectMake(cv.contentOffset.x, cv.contentOffset.y, cv.bounds.size.width, cv.bounds.size.height);
    CGPoint mid = CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis));
    NSInteger curItem = 0, section = ips.firstObject.section;
    CGFloat bestD = CGFLOAT_MAX;
    for (NSIndexPath *ip in ips) {
        UICollectionViewLayoutAttributes *at = [cv layoutAttributesForItemAtIndexPath:ip];
        if (!at) continue;
        CGFloat d = fabs(CGRectGetMidX(at.frame) - mid.x) + fabs(CGRectGetMidY(at.frame) - mid.y);
        if (d < bestD) { bestD = d; curItem = ip.item; section = ip.section; }
    }

    NSInteger total = [cv numberOfItemsInSection:section];
    if (curItem + 1 >= total) { [self noteEnd:now]; return; }

    NSIndexPath *next = [NSIndexPath indexPathForItem:curItem + 1 inSection:section];
    UICollectionViewScrollPosition pos = self.vertical ? UICollectionViewScrollPositionCenteredVertically
                                                      : UICollectionViewScrollPositionCenteredHorizontally;
    self.pageCount++;
    [cv scrollToItemAtIndexPath:next atScrollPosition:pos animated:YES];
    if (self.pageCount % 10 == 1) {
        KLog(@"翻页 %ld/%ld", (long)(curItem + 2), (long)total);
    }
}

- (void)noteEnd:(CFTimeInterval)now {
    if (self.endSince <= 0) self.endSince = now;
    if (now - self.endSince > 1.5) {
        self.running = NO;
        KLog(@"已到末尾");
        [self updateBallLook];
        [self showPanelFor:4];
    }
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void KDAutoScrollInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[KDScroll shared] install];
    });
}
