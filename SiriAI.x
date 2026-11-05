//
//  SiriAI.x
//  Siri AI 跑马灯 —— SpringBoard 侧注入
//
//  职责：
//   1. 检测 Siri 界面出现 / 消失（UIViewController 类名匹配 + SBAssistantController 兜底轮询）
//   2. 在独立高等级透明 UIWindow 上绘制屏幕边缘的圆锥渐变流光 + 底部滚动跑马灯 + 声波条
//   3. 监听设置面板发来的 Darwin 通知，热更新配置 / 预览 / 停止
//
//  过滤 plist：SiriAI.plist —— 只注入 com.apple.springboard
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import "SAIACommon.h"

#pragma mark - 全局状态

static NSDictionary *s_settings = nil;                       // 已合并默认值的配置快照
static NSMutableDictionary<NSString *, NSNumber *> *s_classCache = nil; // VC 类名 -> 是否 Siri
static NSHashTable<UIViewController *> *s_siriVCs = nil;     // 当前可见的 Siri VC（弱引用）
static NSArray<NSString *> *s_keywords = nil;

static void SAIAReloadSettings(void) {
    NSMutableDictionary *m = [SAIADefaults() mutableCopy];
    [m addEntriesFromDictionary:SAIALoadSettings()];
    s_settings = [m copy];

    [s_classCache removeAllObjects];

    NSMutableArray *kw = [NSMutableArray array];
    NSString *raw = [s_settings[kSAIAKeywords] description] ?: @"";
    for (NSString *part in [raw componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [kw addObject:t];
    }
    s_keywords = kw.count ? [kw copy] : @[@"Siri", @"Assistant", @"AFUI", @"SiriPresentation"];
}

static BOOL SAIAIsSiriViewController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = [NSString stringWithUTF8String:class_getName(object_getClass(vc))];
    if (!name) return NO;
    NSNumber *cached = s_classCache[name];
    if (cached) return cached.boolValue;

    BOOL hit = NO;
    for (NSString *kw in s_keywords) {
        if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            hit = YES;
            break;
        }
    }
    s_classCache[name] = @(hit);
    return hit;
}

static inline CGFloat SAIAFloat(NSString *key) {
    return (CGFloat)[s_settings[key] doubleValue];
}
static inline BOOL SAIABool(NSString *key) {
    return [s_settings[key] boolValue];
}
static inline NSInteger SAIAInt(NSString *key) {
    return [s_settings[key] integerValue];
}

#pragma mark - 跑马灯 / 流光视图

@interface SAIAGlowView : UIView
- (void)applySettings;
- (void)startAnimating;
- (void)stopAnimating;
@end

@implementation SAIAGlowView {
    CALayer          *_bloomContainer;   // 外层柔光（宽描边遮罩）
    CALayer          *_coreContainer;    // 内层实光（窄描边遮罩）
    CAGradientLayer  *_bloomGradient;
    CAGradientLayer  *_coreGradient;
    CAShapeLayer     *_bloomMask;
    CAShapeLayer     *_coreMask;

    UIView           *_capsule;
    UIView           *_marqueeClip;
    UILabel          *_marqueeA;
    UILabel          *_marqueeB;
    NSMutableArray<UIView *> *_bars;

    BOOL             _running;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.layer.zPosition = 100000.0;

    _bloomContainer = [CALayer layer];
    _coreContainer  = [CALayer layer];
    [self.layer addSublayer:_bloomContainer];
    [self.layer addSublayer:_coreContainer];

    _bloomMask = [CAShapeLayer layer];
    _bloomMask.fillColor = [UIColor clearColor].CGColor;
    _bloomMask.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.38].CGColor;
    _bloomMask.lineCap = kCALineCapRound;

    _coreMask = [CAShapeLayer layer];
    _coreMask.fillColor = [UIColor clearColor].CGColor;
    _coreMask.strokeColor = [UIColor whiteColor].CGColor;
    _coreMask.lineCap = kCALineCapRound;

    _bloomContainer.mask = _bloomMask;
    _coreContainer.mask  = _coreMask;

    _bloomGradient = [CAGradientLayer layer];
    _coreGradient  = [CAGradientLayer layer];
    [_bloomContainer addSublayer:_bloomGradient];
    [_coreContainer  addSublayer:_coreGradient];

    // 底部胶囊：模糊底 + 声波条 + 无缝滚动文字
    _capsule = [[UIView alloc] initWithFrame:CGRectZero];
    _capsule.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.22];
    _capsule.layer.cornerRadius = 22.0;
    _capsule.clipsToBounds = YES;
    _capsule.userInteractionEnabled = NO;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [_capsule addSubview:blur];
    [self addSubview:_capsule];

    _bars = [NSMutableArray array];
    for (NSUInteger i = 0; i < 7; i++) {
        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        bar.layer.cornerRadius = 1.5;
        [_capsule addSubview:bar];
        [_bars addObject:bar];
    }

    _marqueeClip = [[UIView alloc] initWithFrame:CGRectZero];
    _marqueeClip.clipsToBounds = YES;
    _marqueeClip.userInteractionEnabled = NO;
    [_capsule addSubview:_marqueeClip];

    _marqueeA = [[UILabel alloc] initWithFrame:CGRectZero];
    _marqueeB = [[UILabel alloc] initWithFrame:CGRectZero];
    for (UILabel *l in @[_marqueeA, _marqueeB]) {
        l.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        l.textColor = [UIColor whiteColor];
        l.numberOfLines = 1;
        [_marqueeClip addSubview:l];
    }

    [self applySettings];
    return self;
}

- (void)applySettings {
    NSArray<UIColor *> *colors = SAIAPaletteColors(SAIAInt(kSAIAPalette));
    NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:colors.count];
    NSMutableArray *locations = [NSMutableArray arrayWithCapacity:colors.count];
    for (NSUInteger i = 0; i < colors.count; i++) {
        [cgColors addObject:(__bridge id)colors[i].CGColor];
        [locations addObject:@((double)i / (double)(colors.count - 1))];
    }

    for (CAGradientLayer *g in @[_coreGradient, _bloomGradient]) {
        g.type = kCAGradientLayerConic;
        g.colors = cgColors;
        g.locations = locations;
        // 圆锥渐变：中心在层中央，endPoint 决定起始角度
        g.startPoint = CGPointMake(0.5, 0.5);
        g.endPoint   = CGPointMake(0.5, 0.0);
    }

    CGFloat intensity = MAX(0.05, MIN(1.0, SAIAFloat(kSAIAGlowIntensity)));
    _coreContainer.opacity  = (float)intensity;
    _bloomContainer.opacity = (float)(intensity * 0.62);

    BOOL showMarquee = SAIABool(kSAIAMarqueeEnabled);
    _capsule.hidden = !showMarquee;

    NSString *text = [s_settings[kSAIAMarqueeText] description] ?: @"Siri AI";
    _marqueeA.text = text;
    _marqueeB.text = text;

    [self setNeedsLayout];
    [self layoutIfNeeded];
    if (_running) [self restartAnimations];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    if (w <= 0 || h <= 0) return;

    _bloomContainer.frame = b;
    _coreContainer.frame  = b;
    _bloomMask.frame = b;
    _coreMask.frame  = b;

    CGFloat width = MAX(1.0, SAIAFloat(kSAIAGlowWidth));
    CGFloat radius = SAIAFloat(kSAIACornerRadius);
    if (radius <= 0) radius = 47.0;   // iPhone 屏幕圆角的近似值

    // 描边中心向内侧缩进半个线宽，避免被屏幕边界裁掉
    CGFloat coreInset = width / 2.0 + 0.75;
    CGRect coreRect = CGRectInset(b, coreInset, coreInset);
    _coreMask.path = [UIBezierPath bezierPathWithRoundedRect:coreRect
                                                cornerRadius:MAX(radius - coreInset, 4.0)].CGPath;
    _coreMask.lineWidth = width;

    CGFloat bloomWidth = width * 2.9;
    CGFloat bloomInset = bloomWidth / 2.0 + 0.75;
    CGRect bloomRect = CGRectInset(b, bloomInset, bloomInset);
    _bloomMask.path = [UIBezierPath bezierPathWithRoundedRect:bloomRect
                                                 cornerRadius:MAX(radius - bloomInset, 4.0)].CGPath;
    _bloomMask.lineWidth = bloomWidth;

    // 渐变层取一个能覆盖全屏任意旋转角度的正方形，旋转中心 = 屏幕中心
    CGFloat side = ceil(hypot(w, h)) + 4.0;
    CGRect square = CGRectMake((w - side) / 2.0, (h - side) / 2.0, side, side);
    _coreGradient.frame  = square;
    _bloomGradient.frame = square;

    // 胶囊布局
    CGFloat bottomInset = self.safeAreaInsets.bottom > 1.0 ? self.safeAreaInsets.bottom : 20.0;
    CGFloat capsuleH = 44.0;
    CGRect cap = CGRectMake(20.0, h - bottomInset - capsuleH - 14.0, w - 40.0, capsuleH);
    _capsule.frame = cap;
    for (UIView *v in _capsule.subviews) {
        if ([v isKindOfClass:[UIVisualEffectView class]]) v.frame = _capsule.bounds;
    }

    BOOL waveform = SAIABool(kSAIAWaveform);
    CGFloat barsLeft = 14.0;
    CGFloat barW = 3.0, gap = 3.5, barH = 18.0;
    for (NSUInteger i = 0; i < _bars.count; i++) {
        UIView *bar = _bars[i];
        bar.hidden = !waveform;
        bar.frame = CGRectMake(barsLeft + i * (barW + gap),
                               (capsuleH - barH) / 2.0, barW, barH);
    }

    CGFloat clipX = waveform ? (barsLeft + 7 * (barW + gap) + 8.0) : 16.0;
    _marqueeClip.frame = CGRectMake(clipX, 6.0, cap.size.width - clipX - 14.0, capsuleH - 12.0);

    [_marqueeA sizeToFit];
    [_marqueeB sizeToFit];
    CGFloat textW = MAX(_marqueeA.frame.size.width, 60.0);
    CGFloat total = textW + 44.0;
    _marqueeA.frame = CGRectMake(0, 0, textW, _marqueeClip.frame.size.height);
    _marqueeB.frame = CGRectMake(total, 0, textW, _marqueeClip.frame.size.height);
    _marqueeA.hidden = !SAIABool(kSAIAMarqueeEnabled);
    _marqueeB.hidden = _marqueeA.hidden;

    if (_running) [self restartAnimations];
}

#pragma mark - 动画

- (void)restartAnimations {
    for (CALayer *g in @[_coreGradient, _bloomGradient]) {
        [g removeAnimationForKey:@"saiarotate"];
    }
    for (UIView *bar in _bars) [bar.layer removeAnimationForKey:@"saiabar"];
    [_marqueeA.layer removeAnimationForKey:@"saiamarquee"];
    [_marqueeB.layer removeAnimationForKey:@"saiamarquee"];

    // 1) 屏幕边缘流光：圆锥渐变匀速旋转
    CGFloat duration = MAX(0.5, SAIAFloat(kSAIASpeed));
    for (CAGradientLayer *g in @[_coreGradient, _bloomGradient]) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0.0;
        spin.toValue = @(2.0 * M_PI);
        spin.duration = duration;
        spin.repeatCount = HUGE_VALF;
        spin.removedOnCompletion = NO;
        spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [g addAnimation:spin forKey:@"saiarotate"];
    }

    // 2) 呼吸感：透明度轻微起伏
    [_coreContainer removeAnimationForKey:@"saiapulse"];
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    CGFloat base = MAX(0.05, MIN(1.0, SAIAFloat(kSAIAGlowIntensity)));
    pulse.fromValue = @(base * 0.72);
    pulse.toValue = @(base);
    pulse.duration = 1.6;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.removedOnCompletion = NO;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_coreContainer addAnimation:pulse forKey:@"saiapulse"];

    if (!SAIABool(kSAIAMarqueeEnabled)) return;

    // 3) 文字无缝跑马灯：两个相同 label 同时左移一个周期
    CGFloat textW = MAX(_marqueeA.frame.size.width, 60.0);
    CGFloat total = textW + 44.0;
    CGFloat md = MAX(1.5, SAIAFloat(kSAIAMarqueeDuration));
    for (UILabel *l in @[_marqueeA, _marqueeB]) {
        CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        slide.fromValue = @0.0;
        slide.toValue = @(-total);
        slide.duration = md;
        slide.repeatCount = HUGE_VALF;
        slide.removedOnCompletion = NO;
        slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [l.layer addAnimation:slide forKey:@"saiamarquee"];
    }

    // 4) 声波条
    if (!SAIABool(kSAIAWaveform)) return;
    for (NSUInteger i = 0; i < _bars.count; i++) {
        UIView *bar = _bars[i];
        bar.layer.anchorPoint = CGPointMake(0.5, 0.5);
        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        scale.fromValue = @0.22;
        scale.toValue = @1.0;
        scale.duration = 0.30 + 0.055 * (double)i;
        scale.autoreverses = YES;
        scale.repeatCount = HUGE_VALF;
        scale.removedOnCompletion = NO;
        scale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [bar.layer addAnimation:scale forKey:@"saiabar"];
    }
}

- (void)startAnimating {
    _running = YES;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self restartAnimations];
}

- (void)stopAnimating {
    _running = NO;
    for (CALayer *g in @[_coreGradient, _bloomGradient]) [g removeAnimationForKey:@"saiarotate"];
    [_coreContainer removeAnimationForKey:@"saiapulse"];
    for (UIView *bar in _bars) [bar.layer removeAnimationForKey:@"saiabar"];
    [_marqueeA.layer removeAnimationForKey:@"saiamarquee"];
    [_marqueeB.layer removeAnimationForKey:@"saiamarquee"];
}

@end

#pragma mark - 覆盖层管理

@interface SAIAOverlay : NSObject
+ (instancetype)shared;
- (void)show;
- (void)hide;
- (void)previewForSeconds:(NSTimeInterval)seconds;
- (void)reload;
- (void)startPolling;
@end

@interface SAIAOverlay ()
- (UIWindow *)buildWindow;
- (void)endPreview;
- (void)poll;
@end

@implementation SAIAOverlay {
    UIWindow     *_window;
    SAIAGlowView *_glow;
    NSTimer      *_timeoutTimer;
    NSTimer      *_pollTimer;
    NSDate       *_shownAt;
    BOOL          _visible;
    BOOL          _previewing;
}

+ (instancetype)shared {
    static SAIAOverlay *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[SAIAOverlay alloc] init]; });
    return instance;
}

- (UIWindow *)buildWindow {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }

    UIWindow *win = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                          : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    win.frame = [UIScreen mainScreen].bounds;
    // 高于状态栏与大多数系统层；窗口全透明且不接收触摸，不影响操作
    win.windowLevel = UIWindowLevelStatusBar + 1100.0;
    win.backgroundColor = [UIColor clearColor];
    win.userInteractionEnabled = NO;
    win.hidden = YES;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.userInteractionEnabled = NO;
    win.rootViewController = root;

    _glow = [[SAIAGlowView alloc] initWithFrame:root.view.bounds];
    _glow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:_glow];
    return win;
}

- (void)show {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf show]; });
        return;
    }
    if (!SAIABool(kSAIAEnabled) && !_previewing) return;
    if (!_window) _window = [self buildWindow];

    _shownAt = [NSDate date];
    _visible = YES;
    _window.hidden = NO;
    [_glow applySettings];
    [_glow startAnimating];

    [_timeoutTimer invalidate];
    CGFloat maxDuration = SAIAFloat(kSAIAMaxDuration);
    if (maxDuration > 0) {
        __weak typeof(self) weakSelf = self;
        _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:maxDuration
                                                        repeats:NO
                                                          block:^(NSTimer *t) { [weakSelf hide]; }];
    }
}

- (void)hide {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf hide]; });
        return;
    }
    _visible = NO;
    _previewing = NO;
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
    [_glow stopAnimating];
    _window.hidden = YES;
}

- (void)previewForSeconds:(NSTimeInterval)seconds {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf previewForSeconds:seconds]; });
        return;
    }
    _previewing = YES;
    [self show];
    [_timeoutTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(1.0, seconds)
                                                    repeats:NO
                                                      block:^(NSTimer *t) {
        [weakSelf endPreview];
    }];
}

- (void)endPreview {
    _previewing = NO;
    [self hide];
}

- (void)reload {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reload]; });
        return;
    }
    if (!SAIABool(kSAIAEnabled)) { [self hide]; return; }
    if (_visible) { [_glow applySettings]; [_glow startAnimating]; }
}

// 兜底：若某个固件上 Siri VC 的类名不在关键字表里，
// 通过 SBAssistantController +isVisible 轮询也能把动画拉起来。
- (void)startPolling {
    if (_pollTimer) return;
    __weak typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) {
        [weakSelf poll];
    }];
}

- (void)poll {
    Class cls = objc_getClass("SBAssistantController");
    if (!cls || ![cls respondsToSelector:@selector(isVisible)]) return;

    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    BOOL assistantVisible = fn((id)cls, @selector(isVisible));

    if (assistantVisible && !_visible && !_previewing) {
        [self show];
    } else if (!assistantVisible && _visible && !_previewing &&
               s_siriVCs.count == 0 &&
               _shownAt && [[NSDate date] timeIntervalSinceDate:_shownAt] > 3.0) {
        [self hide];
    }
}

@end

#pragma mark - Darwin 通知

static void SAIANotificationCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    if (CFStringCompare(name, SAIA_N_PREFS, 0) == kCFCompareEqualTo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SAIAReloadSettings();
            [[SAIAOverlay shared] reload];
        });
    } else if (CFStringCompare(name, SAIA_N_PREVIEW, 0) == kCFCompareEqualTo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SAIAReloadSettings();
            [[SAIAOverlay shared] previewForSeconds:5.0];
        });
    } else if (CFStringCompare(name, SAIA_N_STOP, 0) == kCFCompareEqualTo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[SAIAOverlay shared] hide];
        });
    }
}

#pragma mark - Hooks

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    if (SAIAIsSiriViewController(self)) {
        [s_siriVCs addObject:self];
        [[SAIAOverlay shared] show];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig(animated);
    if (SAIAIsSiriViewController(self)) {
        [s_siriVCs removeObject:self];
        if (s_siriVCs.count == 0) [[SAIAOverlay shared] hide];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    if (SAIAIsSiriViewController(self)) {
        [s_siriVCs removeObject:self];
        if (s_siriVCs.count == 0) [[SAIAOverlay shared] hide];
    }
}

%end

%ctor {
    @autoreleasepool {
        s_classCache = [NSMutableDictionary new];
        s_siriVCs = [NSHashTable weakObjectsHashTable];
        SAIAReloadSettings();

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, SAIANotificationCallback,
                                        SAIA_N_PREFS, NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, SAIANotificationCallback,
                                        SAIA_N_PREVIEW, NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, SAIANotificationCallback,
                                        SAIA_N_STOP, NULL, CFNotificationSuspensionBehaviorCoalesce);

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [[SAIAOverlay shared] hide];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[SAIAOverlay shared] startPolling];
        });
    }
}
