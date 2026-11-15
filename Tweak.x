// SiriSound v1.1.2 - Siri 启动音效插件 (rootless / arm64)
// iPhone XR / iOS 16.0.2
//
// v1.1.2 修复（依据设备 debug-3.txt 日志）：
//   debug-3.txt 证明 v1.1.0 一次 Siri 会话内播放了约 25 次系统提示音，
//   触发 iOS 对 AudioServicesPlaySystemSound 的静默节流 → "前几次有声，
//   突然没声"。v1.1.1 的 10 秒死区方案用户不接受（牺牲响应性）。
//   改用实例生命周期检测：用关联对象追踪 SiriUIBackgroundBlurViewController
//   的存活实例数，只在 0→1（新会话开始）时播放一次，dealloc 时重置。
//   一次会话只播一声 → 不重叠、不触发节流；Siri 退出后立即能再响（无死区）。
//   每次播放重建 SystemSoundID，防止长时间使用后失效。
//   附 2.5s 安全防抖兜底（仅当 dealloc 检测异常时生效，不构成感知死区）。
//
// 历史：
//   v1.1.0: AVAudioPlayer → AudioServicesPlaySystemSound，不打断 Siri 录音。
//   v1.0.0: 初版（AVAudioPlayer，会打断录音导致 Siri 下线）。

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

// 关联对象 key（取静态变量地址）
static const char kSSAppearedKey;

static SystemSoundID ssSoundID = 0;
static NSInteger ssAliveCount = 0;       // 已出现且仍存活的 VC 实例数
static NSTimeInterval ssLastPlayTime = 0;

// 安全防抖：略大于音效时长（2.04s），仅当 dealloc 检测异常时兜底，
// 防止真正的音频重叠。正常情况下（dealloc 正常）永不触发。
static const NSTimeInterval kSSSafetyDebounce = 2.5;

static NSString *SSTimeStamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"HH:mm:ss.SSS"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

static void SSLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[SiriSound %@] %@\n", SSTimeStamp(), msg];
    NSLog(@"%@", line);

    NSString *path = @"/var/jb/Library/Application Support/SiriSound/debug.txt";
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static void SSDisposeSound(void) {
    if (ssSoundID) {
        AudioServicesDisposeSystemSoundID(ssSoundID);
        ssSoundID = 0;
    }
}

static void SSPlaySound(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // 安全防抖（兜底）
    if (ssLastPlayTime > 0 && (now - ssLastPlayTime) < kSSSafetyDebounce) {
        SSLog(@"安全防抖跳过（%.2fs）", now - ssLastPlayTime);
        return;
    }

    NSString *path = @"/var/jb/Library/Application Support/SiriSound/SiriSound.caf";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        SSLog(@"音效文件不存在: %@", path);
        return;
    }

    // 每次播放都重建 SystemSoundID：防止长时间复用后失效导致"突然没声"
    SSDisposeSound();
    OSStatus st = AudioServicesCreateSystemSoundID(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], &ssSoundID);
    if (st != noErr) {
        SSLog(@"CreateSystemSoundID 失败: %d", (int)st);
        ssSoundID = 0;
        return;
    }

    ssLastPlayTime = now;
    AudioServicesPlaySystemSound(ssSoundID);
    SSLog(@"播放（系统提示音通道）");
}

// viewDidAppear：基于实例生命周期判定会话边界
static void SSHandleDidAppear(id self) {
    NSNumber *flag = objc_getAssociatedObject(self, &kSSAppearedKey);
    if (flag == nil) {
        // 新实例：标记并计数 +1
        objc_setAssociatedObject(self, &kSSAppearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ssAliveCount++;
        if (ssAliveCount == 1) {
            // 0→1 转换 = 新会话开始 → 播放
            SSLog(@"新会话开始（实例计数 0→1）→ 播放");
            SSPlaySound();
        } else {
            // 会话进行中出现新实例（罕见），不播放
            SSLog(@"新实例加入，计数=%ld（会话中，不播放）", (long)ssAliveCount);
        }
    } else {
        // 同一实例重复 viewDidAppear（iOS 16 已知行为），不播放
        SSLog(@"同实例重复 viewDidAppear，计数=%ld（不播放）", (long)ssAliveCount);
    }
}

// dealloc：实例销毁
static void SSHandleDealloc(id self) {
    NSNumber *flag = objc_getAssociatedObject(self, &kSSAppearedKey);
    if (flag != nil) {
        ssAliveCount--;
        if (ssAliveCount <= 0) {
            ssAliveCount = 0;
            ssLastPlayTime = 0; // 会话结束，重置以便下次召唤立即播放
            SSLog(@"会话结束（实例计数 →0，已重置）");
        } else {
            SSLog(@"实例销毁，计数=%ld", (long)ssAliveCount);
        }
    }
}

%hook SiriUIBackgroundBlurViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewDidAppear");
    SSHandleDidAppear(self);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewWillDisappear");
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewDidDisappear");
}

- (void)dealloc {
    SSHandleDealloc(self);
    %orig;
}

%end

%hook SiriUIContentViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIContentViewController viewDidAppear");
    SSHandleDidAppear(self);
}

- (void)dealloc {
    SSHandleDealloc(self);
    %orig;
}

%end

%ctor {
    SSLog(@"v1.1.2 已加载到进程: %@ (%@)",
          [[NSProcessInfo processInfo] processName],
          [[NSBundle mainBundle] bundleIdentifier]);
}
