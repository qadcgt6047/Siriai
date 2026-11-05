//
//  SAIACommon.h
//  Siri AI 跑马灯 (iOS 16 / roothide)
//
//  SpringBoard 侧注入 (SiriAI.dylib) 与 设置侧注入 (SiriAIPrefs.dylib) 共用的
//  配置读写、默认值、配色定义。
//
//  关键点：配置文件放在 NSHomeDirectory()/Library/Preferences/ 下。
//  SpringBoard 与 Preferences.app 都以 mobile 用户运行，因此这个路径在
//  rootful / rootless / roothide 三种方案下都无需任何 jbroot 路径转换。
//

#ifndef SAIACommon_h
#define SAIACommon_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

#define SAIA_PREFS_DOMAIN   @"com.siriai16.prefs"
#define SAIA_N_PREFS        CFSTR("com.siriai16.prefs/changed")
#define SAIA_N_PREVIEW      CFSTR("com.siriai16.prefs/preview")
#define SAIA_N_STOP         CFSTR("com.siriai16.prefs/stop")

#define SAIA_N_PREFS_STR    @"com.siriai16.prefs/changed"

// PSSpecifier 上我们自定义的 marker 键（避免和系统键冲突）
#define SAIA_MARKER_REPLACED @"SAIAReplaced"
#define SAIA_MARKER_NATIVE   @"SAIANativeSiri"
#define SAIA_MARKER_OURS     @"SAIAOwnCell"
#define SAIA_MARKER_KEY      @"SAIAKey"
#define SAIA_MARKER_ACTION   @"SAIAAction"

// 配置键
#define kSAIAEnabled          @"enabled"
#define kSAIAReplaceCell      @"replaceSiriCell"
#define kSAIACustomLabel      @"customLabel"
#define kSAIAPalette          @"palette"
#define kSAIASpeed            @"speed"
#define kSAIAGlowWidth        @"glowWidth"
#define kSAIAGlowIntensity    @"glowIntensity"
#define kSAIACornerRadius     @"cornerRadius"
#define kSAIAMarqueeEnabled   @"marqueeEnabled"
#define kSAIAMarqueeText      @"marqueeText"
#define kSAIAMarqueeDuration  @"marqueeDuration"
#define kSAIAWaveform         @"waveform"
#define kSAIAMaxDuration      @"maxDuration"
#define kSAIAKeywords         @"keywords"

NS_INLINE NSString *SAIAPrefsPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.siriai16.prefs.plist"];
}

NS_INLINE NSDictionary *SAIALoadSettings(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SAIAPrefsPath()];
    return d ?: @{};
}

NS_INLINE void SAIASaveSettings(NSDictionary *settings) {
    NSString *path = SAIAPrefsPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [settings writeToFile:path atomically:YES];
}

NS_INLINE NSDictionary *SAIADefaults(void) {
    static NSDictionary *defaults = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = @{
            kSAIAEnabled:         @YES,
            kSAIAReplaceCell:     @YES,
            kSAIACustomLabel:     @"Siri AI",
            kSAIAPalette:         @0,
            kSAIASpeed:           @3.2,   // 秒/圈
            kSAIAGlowWidth:       @6.0,   // pt
            kSAIAGlowIntensity:   @0.90,
            kSAIACornerRadius:    @0,     // 0 = 自动
            kSAIAMarqueeEnabled:  @YES,
            kSAIAMarqueeText:     @"Siri AI  ✦  Thinking…  ✦  Apple Intelligence  ✦  ",
            kSAIAMarqueeDuration: @9.0,   // 秒/循环
            kSAIAWaveform:        @YES,
            kSAIAMaxDuration:     @0,     // 0 = 不限时
            kSAIAKeywords:        @"Siri,Assistant,AFUI,SiriPresentation,SNLA,VSSiri"
        };
    });
    return defaults;
}

// 读单个配置项（带默认值兜底）
NS_INLINE id SAIAValue(NSDictionary *settings, NSString *key) {
    id v = settings[key];
    return v ?: SAIADefaults()[key];
}

NS_INLINE void SAIAPost(CFStringRef name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         name, NULL, NULL, YES);
}

NS_INLINE UIColor *SAIAColorFromHex(NSString *hex) {
    NSString *clean = [hex stringByTrimmingCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@"#"]];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&rgb];
    return [UIColor colorWithRed:(((rgb >> 16) & 0xFF) / 255.0)
                           green:(((rgb >>  8) & 0xFF) / 255.0)
                            blue:(((rgb      ) & 0xFF) / 255.0)
                           alpha:1.0];
}

// 每套配色首尾同色，保证圆锥渐变旋转时无缝衔接
NS_INLINE NSArray<UIColor *> *SAIAPaletteColors(NSInteger index) {
    NSArray *hexes;
    switch (index) {
        case 1:  // 极光
            hexes = @[@"#00E5FF", @"#3B82F6", @"#8B5CF6", @"#22D3EE", @"#00E5FF"];
            break;
        case 2:  // 霓虹
            hexes = @[@"#FF2D55", @"#FF9500", @"#FFCC00", @"#34C759",
                      @"#00C7BE", @"#5E5CE6", @"#FF2D55"];
            break;
        case 3:  // 银白
            hexes = @[@"#FFFFFF", @"#AEAEB2", @"#F2F2F7", @"#8E8E93", @"#FFFFFF"];
            break;
        default: // Apple Intelligence 官方观感
            hexes = @[@"#BC82F3", @"#F5B9EA", @"#8D9FFF", @"#AA6EEE",
                      @"#FF6778", @"#FFBA71", @"#C686FF", @"#BC82F3"];
            break;
    }
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:hexes.count];
    for (NSString *h in hexes) [out addObject:SAIAColorFromHex(h)];
    return out;
}

#endif /* SAIACommon_h */
