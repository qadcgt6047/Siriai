# SiriSound - Siri 启动音效插件（Theos 版，arm64e）
# Rootless / iPhone XR / iOS 16.0.2
#
# 原理：hook SpringBoard 里 Siri UI 的显示生命周期，出现时播放 MP3
# 用 AudioServicesPlaySystemSound（底层 API，不配音频会话，不与 Siri 录音冲突）

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

static SystemSoundID g_soundID = 0;
static IMP g_origAppear = NULL;
static IMP g_origDisappear = NULL;

/* 写调试日志到文件（Filza 可看） */
static void SSLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[SiriSound] %@\n", msg];
    NSLog(@"%@", line);

    NSString *path = @"/var/jb/Library/Application Support/SiriSound/debug.txt";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

static void SSPlaySound(void) {
    /* 释放旧的 */
    if (g_soundID != 0) {
        AudioServicesDisposeSystemSoundID(g_soundID);
        g_soundID = 0;
    }

    NSString *path = @"/var/jb/Library/Application Support/SiriSound/SiriSound.mp3";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        SSLog(@"MP3 not found: %@", path);
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    SystemSoundID sid = 0;
    OSStatus err = AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &sid);
    if (err != 0) {
        SSLog(@"CreateSystemSoundID err=%d", (int)err);
        return;
    }
    g_soundID = sid;
    AudioServicesPlaySystemSound(sid);
    SSLog(@"playing sound id=%u", (unsigned)sid);
}

static void SSStopSound(void) {
    /* SystemSound 播完自动停，无需手动 */
}

/* viewDidAppear: 被调用 */
static void ss_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    SSLog(@"viewDidAppear on %@", NSStringFromClass(object_getClass(self)));
    if (g_origAppear) {
        ((void (*)(id, SEL, BOOL))g_origAppear)(self, _cmd, animated);
    }
    SSPlaySound();
}

/* viewDidDisappear: 被调用 */
static void ss_viewDidDisappear(id self, SEL _cmd, BOOL animated) {
    SSLog(@"viewDidDisappear on %@", NSStringFromClass(object_getClass(self)));
    if (g_origDisappear) {
        ((void (*)(id, SEL, BOOL))g_origDisappear)(self, _cmd, animated);
    }
    SSStopSound();
}

static BOOL SSSwizzle(Class cls, SEL sel, IMP newImp, IMP *origStore) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP old = method_getImplementation(m);
    if (origStore) *origStore = old;
    method_setImplementation(m, newImp);
    return YES;
}

%ctor {
    SSLog(@"dylib loaded, process=%@", [[NSProcessInfo processInfo] processName]);

    NSArray *candidates = @[
        @"SiriUIBackgroundBlurViewController",
        @"SiriUIContentViewController",
        @"SiriUIViewController",
        @"SiriUIPresentationController",
        @"AFUISiriViewController",
        @"AFUISiriView",
        @"AFUIStarkSiriViewController",
        @"SiriViewController",
        @"SiriWindow",
    ];

    int hooked = 0;
    for (NSString *name in candidates) {
        Class cls = NSClassFromString(name);
        if (!cls) {
            SSLog(@"class not found: %@", name);
            continue;
        }
        IMP oa = NULL, od = NULL;
        BOOL okA = SSSwizzle(cls, @selector(viewDidAppear:), (IMP)ss_viewDidAppear, &oa);
        BOOL okD = SSSwizzle(cls, @selector(viewDidDisappear:), (IMP)ss_viewDidDisappear, &od);
        if (okA) g_origAppear = oa;
        if (okD) g_origDisappear = od;
        if (okA || okD) {
            SSLog(@"hooked %@ (appear=%d disappear=%d)", name, okA, okD);
            hooked++;
        }
    }
    SSLog(@"hooked %d classes", hooked);
}
