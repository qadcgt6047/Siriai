//
//  SiriAIPrefs.x
//  Siri AI 跑马灯 —— Settings.app 侧注入
//
//  职责：
//   1. 在设置根列表中定位系统的「Siri 与搜索」控制项，改标题并接管点击，
//      让其打开本插件的设置面板（原来的原生 Siri 设置仍可从面板内进入）。
//   2. 提供一个完全用代码构造的 PSListController 面板，无需 PreferenceBundle，
//      因此不存在 roothide 下 /Library/PreferenceBundles 的路径转换问题。
//
//  过滤 plist：SiriAIPrefs.plist —— 只注入 com.apple.Preferences
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SAIACommon.h"
#import "PrefsShims.h"

#pragma mark - 辅助函数

static NSDictionary *s_originalSiriProperties = nil;  // 首次命中时保存原生 Siri 项的属性
static char kSAIASpecsKey;

static NSDictionary *SAIAProperties(PSSpecifier *spec) {
    if ([spec respondsToSelector:@selector(properties)]) {
        NSDictionary *p = [spec properties];
        if ([p isKindOfClass:[NSDictionary class]]) return p;
    }
    // 极少数固件上 properties 不可用时，退化为按已知键逐个读取
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"id", @"identifier", @"label", @"name", @"bundle", @"pane",
                          @"detail", @"icon", @"iconID", @"url", @"defaults", @"cell",
                          @"isController", @"key", @"action"]) {
        id v = [spec propertyForKey:k];
        if (v) m[k] = v;
    }
    return m;
}

static NSString *SAIAStringFromProperty(id value) {
    if (!value) return @"";
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if (class_isMetaClass(object_getClass(value))) {
        return NSStringFromClass((Class)value) ?: @"";
    }
    return [value description] ?: @"";
}

// 纯内容判定：这个 specifier 是不是「跳到 Siri 设置」的那一格
static BOOL SAIAIsSiriCellRaw(PSSpecifier *spec) {
    if (!spec || ![spec respondsToSelector:@selector(propertyForKey:)]) return NO;
    NSDictionary *props = SAIAProperties(spec);

    NSMutableArray *haystack = [NSMutableArray array];
    for (NSString *k in @[@"id", @"identifier", @"label", @"name", @"bundle", @"pane",
                          @"detail", @"icon", @"iconID", @"url", @"defaults"]) {
        id v = props[k];
        if (v) [haystack addObject:SAIAStringFromProperty(v)];
    }
    NSString *sid = [spec respondsToSelector:@selector(identifier)] ? [spec identifier] : nil;
    NSString *snm = [spec respondsToSelector:@selector(name)] ? [spec name] : nil;
    if (sid) [haystack addObject:sid];
    if (snm) [haystack addObject:snm];

    BOOL hasSiri = NO;
    for (NSString *s in haystack) {
        if ([s rangeOfString:@"siri" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            hasSiri = YES;
            break;
        }
    }
    if (!hasSiri) return NO;

    // 只接管可跳转的 cell，避免误伤 Siri 页面内部的开关
    NSString *cellName = SAIAStringFromProperty(props[@"cell"]);
    BOOL linkish = [cellName rangeOfString:@"Link" options:NSCaseInsensitiveSearch].location != NSNotFound
                || props[@"detail"] != nil || props[@"bundle"] != nil || props[@"pane"] != nil;
    return linkish;
}

static BOOL SAIAIsRootLevel(UIViewController *controller) {
    UINavigationController *nav = controller.navigationController;
    return nav == nil || nav.viewControllers.count <= 1;
}

static BOOL SAIABoolFromDisk(NSString *key, BOOL fallback) {
    id v = SAIALoadSettings()[key];
    return v ? [v boolValue] : fallback;
}

static NSString *SAIAStringFromDisk(NSString *key, NSString *fallback) {
    NSString *v = [SAIALoadSettings()[key] description];
    return v.length ? v : fallback;
}

#pragma mark - 自定义设置面板

@interface SAIASettingsListController : PSListController
@end

@interface SAIASettingsListController ()
- (NSMutableArray *)buildSpecifiers;
- (PSSpecifier *)makeGroup:(NSString *)title footer:(NSString *)footer;
- (PSSpecifier *)makeCell:(NSString *)title
                cellClass:(NSString *)cellClass
              detailClass:(Class)detailClass
                      key:(NSString *)key
                    extra:(NSDictionary *)extra;
- (PSSpecifier *)makeAction:(NSString *)title selector:(SEL)selector;
- (PSSpecifier *)makeNativeSiriLink;
- (void)previewAction;
- (void)stopAction;
- (void)openNativeFallback;
- (void)resetAction;
@end

@implementation SAIASettingsListController

- (NSArray *)specifiers {
    NSMutableArray *specs = objc_getAssociatedObject(self, &kSAIASpecsKey);
    if (!specs) {
        specs = [self buildSpecifiers];
        objc_setAssociatedObject(self, &kSAIASpecsKey, specs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return specs;
}

#pragma mark specifier 构造工具

- (PSSpecifier *)makeGroup:(NSString *)title footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:(title ?: @"")
                                                    target:self
                                                       set:NULL
                                                       get:NULL
                                                    detail:Nil
                                                      cell:NSClassFromString(@"PSGroupCell")
                                                      edit:Nil];
    if (footer) [s setProperty:footer forKey:@"footerText"];
    return s;
}

- (PSSpecifier *)makeCell:(NSString *)title
                cellClass:(NSString *)cellClass
              detailClass:(Class)detailClass
                      key:(NSString *)key
                    extra:(NSDictionary *)extra {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:detailClass
                                                      cell:NSClassFromString(cellClass)
                                                      edit:Nil];
    if (key) {
        [s setProperty:key forKey:SAIA_MARKER_KEY];
        [s setProperty:key forKey:@"key"];
        [s setProperty:SAIA_PREFS_DOMAIN forKey:@"defaults"];
        id def = SAIADefaults()[key];
        if (def) [s setProperty:def forKey:@"default"];
    }
    for (NSString *k in extra) [s setProperty:extra[k] forKey:k];
    return s;
}

- (PSSpecifier *)makeAction:(NSString *)title selector:(SEL)selector {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:self
                                                       set:NULL
                                                       get:NULL
                                                    detail:Nil
                                                      cell:NSClassFromString(@"PSButtonCell")
                                                      edit:Nil];
    [s setProperty:NSStringFromSelector(selector) forKey:SAIA_MARKER_ACTION];
    [s setProperty:@YES forKey:@"enabled"];
    [s setProperty:@YES forKey:SAIA_MARKER_OURS];
    return s;
}

// 用保存下来的原生属性重建一个链接格；点击时交给系统原实现推入原生 Siri 面板
- (PSSpecifier *)makeNativeSiriLink {
    if (!s_originalSiriProperties) {
        return [self makeAction:@"打开系统 Siri 与搜索" selector:@selector(openNativeFallback)];
    }
    PSSpecifier *p = [PSSpecifier preferenceSpecifierNamed:@"系统 Siri 与搜索"
                                                    target:self
                                                       set:NULL
                                                       get:NULL
                                                    detail:Nil
                                                      cell:NSClassFromString(@"PSLinkCell")
                                                      edit:Nil];
    NSArray *skip = @[@"label", @"name", @"id", @"identifier", @"cell", @"target",
                      @"set", @"get", @"action", @"key", @"defaults", @"default",
                      @"PostNotification", SAIA_MARKER_REPLACED, SAIA_MARKER_NATIVE,
                      SAIA_MARKER_KEY, SAIA_MARKER_ACTION, SAIA_MARKER_OURS];
    for (NSString *k in s_originalSiriProperties) {
        if ([skip containsObject:k]) continue;
        [p setProperty:s_originalSiriProperties[k] forKey:k];
    }
    [p setProperty:@"系统 Siri 与搜索" forKey:@"label"];
    if ([p respondsToSelector:@selector(setName:)]) [p setName:@"系统 Siri 与搜索"];
    [p setProperty:@YES forKey:SAIA_MARKER_NATIVE];
    [p setProperty:@YES forKey:SAIA_MARKER_OURS];
    return p;
}

#pragma mark 面板内容

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *s = [NSMutableArray array];

    [s addObject:[self makeGroup:@"Siri AI"
                          footer:@"唤醒 Siri 时，屏幕边缘会出现类似 Apple Intelligence 的彩色圆锥渐变流光，底部附带滚动跑马灯与声波条。所有修改即时生效，无需 Respring。"]];
    [s addObject:[self makeCell:@"启用跑马灯动画"
                      cellClass:@"PSSwitchCell" detailClass:Nil key:kSAIAEnabled extra:nil]];
    [s addObject:[self makeAction:@"预览 5 秒" selector:@selector(previewAction)]];
    [s addObject:[self makeAction:@"立即停止动画" selector:@selector(stopAction)]];

    [s addObject:[self makeGroup:@"外观"
                          footer:@"旋转速度单位为「秒 / 圈」，数值越小越快。圆角半径设 0 为自动（约 47pt）。"]];
    [s addObject:[self makeCell:@"配色方案"
                      cellClass:@"PSLinkListCell"
                    detailClass:NSClassFromString(@"PSListItemsController")
                            key:kSAIAPalette
                          extra:@{@"values": @[@0, @1, @2, @3],
                                  @"titles": @[@"Apple Intelligence", @"极光蓝紫", @"霓虹彩虹", @"银白单色"]}]];
    [s addObject:[self makeCell:@"旋转速度"
                      cellClass:@"PSSliderCell" detailClass:Nil key:kSAIASpeed
                          extra:@{@"min": @0.8, @"max": @8.0, @"showValue": @YES}]];
    [s addObject:[self makeCell:@"光带宽度"
                      cellClass:@"PSSliderCell" detailClass:Nil key:kSAIAGlowWidth
                          extra:@{@"min": @2.0, @"max": @18.0, @"showValue": @YES}]];
    [s addObject:[self makeCell:@"辉光强度"
                      cellClass:@"PSSliderCell" detailClass:Nil key:kSAIAGlowIntensity
                          extra:@{@"min": @0.1, @"max": @1.0, @"showValue": @YES}]];
    [s addObject:[self makeCell:@"圆角半径"
                      cellClass:@"PSSliderCell" detailClass:Nil key:kSAIACornerRadius
                          extra:@{@"min": @0.0, @"max": @80.0, @"showValue": @YES}]];

    [s addObject:[self makeGroup:@"跑马灯文字"
                          footer:@"留空则只显示边缘流光。文字滚动速度单位为「秒 / 循环」。"]];
    [s addObject:[self makeCell:@"显示跑马灯"
                      cellClass:@"PSSwitchCell" detailClass:Nil key:kSAIAMarqueeEnabled extra:nil]];
    [s addObject:[self makeCell:@"显示声波条"
                      cellClass:@"PSSwitchCell" detailClass:Nil key:kSAIAWaveform extra:nil]];
    [s addObject:[self makeCell:@"文字内容"
                      cellClass:@"PSEditTextCell" detailClass:Nil key:kSAIAMarqueeText
                          extra:@{@"placeholder": @"Siri AI"}]];
    [s addObject:[self makeCell:@"文字滚动速度"
                      cellClass:@"PSSliderCell" detailClass:Nil key:kSAIAMarqueeDuration
                          extra:@{@"min": @2.0, @"max": @20.0, @"showValue": @YES}]];

    [s addObject:[self makeGroup:@"高级"
                          footer:@"最长显示时间 0 = 不限时。若你的固件上 Siri 界面类名不同，可在「Siri 界面类名关键字」里追加（英文逗号分隔），或依赖 SBAssistantController 轮询兜底。"]];
    [s addObject:[self makeCell:@"替换系统 Siri 控制项"
                      cellClass:@"PSSwitchCell" detailClass:Nil key:kSAIAReplaceCell extra:nil]];
    [s addObject:[self makeCell:@"控制项显示名称"
                      cellClass:@"PSEditTextCell" detailClass:Nil key:kSAIACustomLabel
                          extra:@{@"placeholder": @"Siri AI"}]];
    [s addObject:[self makeCell:@"最长显示时间（秒）"
                      cellClass:@"PSSliderCell" detailClass:Nil key:kSAIAMaxDuration
                          extra:@{@"min": @0.0, @"max": @120.0, @"showValue": @YES}]];
    [s addObject:[self makeCell:@"Siri 界面类名关键字"
                      cellClass:@"PSEditTextCell" detailClass:Nil key:kSAIAKeywords
                          extra:@{@"placeholder": @"Siri,Assistant,AFUI"}]];

    [s addObject:[self makeGroup:@"系统入口" footer:nil]];
    [s addObject:[self makeNativeSiriLink]];

    [s addObject:[self makeGroup:nil
                          footer:@"Siri AI 跑马灯 1.0.0 · iOS 16.0.2 / roothide (arm64e)\n本插件只做界面绘制，不修改 Siri 语音与识别逻辑。"]];
    [s addObject:[self makeAction:@"恢复默认设置" selector:@selector(resetAction)]];

    return s;
}

#pragma mark 读写配置（直接读写 plist，绕开 cfprefsd，跨进程立即可见）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:SAIA_MARKER_KEY];
    if (!key) return nil;
    id v = SAIALoadSettings()[key];
    return v ?: SAIADefaults()[key];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:SAIA_MARKER_KEY];
    if (!key || !value) return;
    NSMutableDictionary *d = [SAIALoadSettings() mutableCopy];
    d[key] = value;
    SAIASaveSettings(d);
    SAIAPost(SAIA_N_PREFS);
}

#pragma mark 动作

- (void)previewAction {
    SAIAPost(SAIA_N_PREFS);
    SAIAPost(SAIA_N_PREVIEW);
}

- (void)stopAction {
    SAIAPost(SAIA_N_STOP);
}

- (void)openNativeFallback {
    NSURL *url = [NSURL URLWithString:@"prefs:root=Siri"];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)resetAction {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复默认设置"
                                                                  message:@"所有跑马灯选项会重置为初始值。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [[NSFileManager defaultManager] removeItemAtPath:SAIAPrefsPath() error:NULL];
        objc_setAssociatedObject(strongSelf, &kSAIASpecsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SAIAPost(SAIA_N_PREFS);
        if ([strongSelf respondsToSelector:@selector(reloadSpecifiers)]) [strongSelf reloadSpecifiers];
        if ([strongSelf respondsToSelector:@selector(reload)]) [strongSelf reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Hooks

%hook PSListController

// 把设置根列表里系统 Siri 项的标题换成我们的，并打上标记
- (id)specifiers {
    id specs = %orig;
    if ([self isKindOfClass:[SAIASettingsListController class]]) return specs;
    if (![specs isKindOfClass:[NSArray class]]) return specs;
    if (!SAIAIsRootLevel(self)) return specs;
    if (!SAIABoolFromDisk(kSAIAReplaceCell, YES)) return specs;

    NSString *label = SAIAStringFromDisk(kSAIACustomLabel, @"Siri AI");
    BOOL foundOurEntry = NO;
    for (PSSpecifier *spec in (NSArray *)specs) {
        if (![spec respondsToSelector:@selector(propertyForKey:)]) continue;
        if ([[spec propertyForKey:SAIA_MARKER_NATIVE] boolValue]) continue;
        if ([[spec propertyForKey:SAIA_MARKER_OURS] boolValue]) { foundOurEntry = YES; continue; }
        if ([[spec propertyForKey:SAIA_MARKER_REPLACED] boolValue]) continue;
        if (!SAIAIsSiriCellRaw(spec)) continue;

        if (!s_originalSiriProperties) s_originalSiriProperties = [SAIAProperties(spec) copy];
        [spec setProperty:label forKey:@"label"];
        if ([spec respondsToSelector:@selector(setName:)]) [spec setName:label];
        [spec setProperty:@YES forKey:SAIA_MARKER_REPLACED];
    }

    // 备用入口：万一某个固件的 Siri 项命名不同导致上面的定位失败，
    // 设置根列表底部仍有一个一定能打开本面板的链接（由代码构造，不依赖 PreferenceBundle 路径）。
    if (!foundOurEntry && [specs isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *m = (NSMutableArray *)specs;
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Siri AI"
                                                            target:self set:NULL get:NULL
                                                            detail:Nil
                                                              cell:NSClassFromString(@"PSGroupCell")
                                                              edit:Nil];
        // detail 传入真实的 Class 对象，由系统按 PSLinkCell 正常推入
        PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:@"跑马灯设置"
                                                           target:self set:NULL get:NULL
                                                           detail:[SAIASettingsListController class]
                                                             cell:NSClassFromString(@"PSLinkCell")
                                                             edit:Nil];
        [link setProperty:@YES forKey:@"isController"];
        [link setProperty:@YES forKey:SAIA_MARKER_OURS];
        [m addObject:group];
        [m addObject:link];
    }
    return specs;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // 我们自己的面板：动作按钮自己处理，其余（开关 / 滑块 / 原生链接）交给系统
    if ([self isKindOfClass:[SAIASettingsListController class]]) {
        PSSpecifier *spec = [self respondsToSelector:@selector(specifierAtIndexPath:)]
                          ? [self specifierAtIndexPath:indexPath] : nil;
        NSString *action = [spec propertyForKey:SAIA_MARKER_ACTION];
        if (action.length) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            SEL sel = NSSelectorFromString(action);
            if ([self respondsToSelector:sel]) {
                [self performSelector:sel withObject:nil afterDelay:0];
            }
            return;
        }
        %orig(tableView, indexPath);
        return;
    }

    if (SAIABoolFromDisk(kSAIAReplaceCell, YES) && SAIAIsRootLevel(self)) {
        PSSpecifier *spec = [self respondsToSelector:@selector(specifierAtIndexPath:)]
                          ? [self specifierAtIndexPath:indexPath] : nil;
        // 优先用 -specifiers 打上的标记（用户自定义了不含 "Siri" 的标题时也能命中），
        // 标记缺失时退化为按内容判定
        BOOL alreadyMarked = [[spec propertyForKey:SAIA_MARKER_REPLACED] boolValue];
        if ((alreadyMarked || SAIAIsSiriCellRaw(spec)) &&
            ![[spec propertyForKey:SAIA_MARKER_NATIVE] boolValue] &&
            ![[spec propertyForKey:SAIA_MARKER_OURS] boolValue]) {
            if (!s_originalSiriProperties) s_originalSiriProperties = [SAIAProperties(spec) copy];
            [tableView deselectRowAtIndexPath:indexPath animated:YES];

            SAIASettingsListController *vc = [[SAIASettingsListController alloc] init];
            vc.title = SAIAStringFromDisk(kSAIACustomLabel, @"Siri AI");
            [self.navigationController pushViewController:vc animated:YES];
            return;
        }
    }

    %orig(tableView, indexPath);
}

%end
