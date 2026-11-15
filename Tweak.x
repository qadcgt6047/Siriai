// SiriSound v1.1.1 - Siri 启动音效插件 (rootless / arm64)
// iPhone XR / iOS 16.0.2
//
// v1.1.1 修复（依据设备 debug-2.txt 日志）：
//   v1.1.0 的日志证明 viewDidAppear 在整个 Siri 会话期间持续触发
//   （间隔 1.5~4s，每轮对话/UI 状态变化都会重现控制器），5 秒防抖
//   窗口一过就会再播一次，造成"隐约重复/重叠"的听感。
//   改为「爆发流检测」：只有当上一个 viewDidAppear 距今超过 10 秒
//   （= 新召唤 Siri，而不是会话内的连续事件）才播放，一次会话只播
//   第一声。日志同时加了时间戳便于诊断。
//
// v1.1.0 修复：
//   1. 防抖：iOS 16 一次 Siri 会话会多次触发 viewDidAppear
//   2. 改用 AudioServicesPlaySystemSound 系统提示音通道，完全不经过
//      AVAudioSession，不打断 Siri 的录音会话（此前 AVAudioPlayer
//      抢占音频会话导致 Siri 直接下线）

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

static SystemSoundID ssSoundID = 0;
static NSTimeInterval ssLastPlayTime = 0;
static NSTimeInterval ssLastEventTime = 0;

// 爆发流间隔：上一个 viewDidAppear 距今超过该值视为「新召唤」。
// 实测会话内事件间隔为 1.5~6s，10 秒可覆盖；Siri 退出后再次召唤
// 通常间隔超过 10 秒。
static const NSTimeInterval kSSNewSummonGap = 10.0;

// 二次保险：距上次播放的最小间隔
static const NSTimeInterval kSSPlayDebounce = 5.0;

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

static void SSPlaySound(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // 爆发流检测：上一个 viewDidAppear 距今 < 10s，说明 Siri 会话仍在
    // 进行中（会话内事件每 1.5~6s 一次），不是新召唤，跳过。
    if (ssLastEventTime > 0 && (now - ssLastEventTime) < kSSNewSummonGap) {
        SSLog(@"会话内事件，跳过（距上一事件 %.2fs）", now - ssLastEventTime);
        ssLastEventTime = now;
        return;
    }
    ssLastEventTime = now;

    // 二次保险
    if (ssLastPlayTime > 0 && (now - ssLastPlayTime) < kSSPlayDebounce) {
        SSLog(@"防抖跳过（%.2fs 内已播放过）", now - ssLastPlayTime);
        return;
    }

    NSString *path = @"/var/jb/Library/Application Support/SiriSound/SiriSound.caf";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        SSLog(@"音效文件不存在: %@", path);
        return;
    }

    // 系统提示音 ID 只创建一次，重复播放复用
    if (ssSoundID == 0) {
        OSStatus st = AudioServicesCreateSystemSoundID(
            (__bridge CFURLRef)[NSURL fileURLWithPath:path], &ssSoundID);
        if (st != noErr) {
            SSLog(@"CreateSystemSoundID 失败: %d", (int)st);
            ssSoundID = 0;
            return;
        }
    }

    ssLastPlayTime = now;
    // 系统提示音通道：不经过 AVAudioSession，不打断 Siri 录音
    AudioServicesPlaySystemSound(ssSoundID);
    SSLog(@"新召唤，播放（系统提示音通道）");
}

%hook SiriUIBackgroundBlurViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewDidAppear");
    SSPlaySound();
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // 诊断 + 若能触发则提前重置，加快再次召唤的响应
    SSLog(@"SiriUIBackgroundBlurViewController viewWillDisappear（重置）");
    ssLastEventTime = 0;
    ssLastPlayTime = 0;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewDidDisappear（重置）");
    ssLastEventTime = 0;
    ssLastPlayTime = 0;
}

%end

%hook SiriUIContentViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIContentViewController viewDidAppear");
    SSPlaySound();
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIContentViewController viewWillDisappear（重置）");
    ssLastEventTime = 0;
    ssLastPlayTime = 0;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIContentViewController viewDidDisappear（重置）");
    ssLastEventTime = 0;
    ssLastPlayTime = 0;
}

%end

%ctor {
    SSLog(@"v1.1.1 已加载到进程: %@ (%@)",
          [[NSProcessInfo processInfo] processName],
          [[NSBundle mainBundle] bundleIdentifier]);
}
