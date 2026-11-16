// SiriSound v1.1.4 - Siri 启动音效插件 (rootless / arm64)
// iPhone XR / iOS 16.0.2
//
// v1.1.4 修复（用户反馈：日志无限增长）：
//   SSLog 写入前检查 debug.txt 大小，达到 10MB 即删除旧文件并重建。
//   新文件首行写入轮转标记（含旧文件大小），便于诊断。
//   日志不会再无限膨胀。
//
// v1.1.3 修复（用户反馈 + 实测）：
//   在 v1.1.2 实例生命周期检测基础上，加 1.7 秒爆发流地板。
//   用户实测：关掉 Siri 马上再召唤，1.7 秒内不会再响 —— 以此为爆发流阈值。
//   dealloc 时不再重置播放时间戳，让 1.7s 地板持续生效，防止快速
//   dismiss+再召唤时重复响；正常会话（>1.7s）再次召唤时地板自然放行。
//   实例生命周期检测仍为一次会话只播一声的主闸门（防重叠）。
//
// 历史：
//   v1.1.2: 实例生命周期检测，一次会话一声，修复突然没声（节流）。
//   v1.1.1: 10s 爆发流（用户不接受，死区太长）。
//   v1.1.0: AudioServicesPlaySystemSound，不打断 Siri 录音。
//   v1.0.0: 初版（AVAudioPlayer，会打断录音导致 Siri 下线）。

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

// 关联对象 key（取静态变量地址）
static const char kSSAppearedKey;

static SystemSoundID ssSoundID = 0;
static NSInteger ssAliveCount = 0;       // 已出现且仍存活的 VC 实例数
static NSTimeInterval ssLastPlayTime = 0;

// 爆发流地板（用户实测）：关掉 Siri 马上再召唤，1.7 秒内不会再响。
// 作为实例生命周期检测的第二道闸门，防止快速 dismiss+再召唤时重复响。
// 正常会话期间由实例生命周期检测保证只播一声，此地板极少触发。
static const NSTimeInterval kSSBurstFloor = 1.7;

static NSString *SSTimeStamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"HH:mm:ss.SSS"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

// 日志大小上限：达到即自动删除旧文件并新建（防止 debug.txt 无限增长）
static const NSUInteger kSSMaxLogBytes = 10 * 1024 * 1024; // 10 MB

static void SSLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[SiriSound %@] %@\n", SSTimeStamp(), msg];
    NSLog(@"%@", line);

    NSString *path = @"/var/jb/Library/Application Support/SiriSound/debug.txt";
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

    // 日志轮转：文件大小达到 10MB 时删除旧文件并重建
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long fileSize = [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
    if (fileSize >= kSSMaxLogBytes) {
        [fm removeItemAtPath:path error:nil];
        // 在新文件第一行写一条轮转标记，便于诊断
        NSString *rotLine = [NSString stringWithFormat:
            @"[SiriSound %@] 日志已轮转（旧文件 %.2f MB，已删除并重建）\n",
            SSTimeStamp(), (double)fileSize / (1024.0 * 1024.0)];
        [rotLine writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[SiriSound] 日志已轮转（旧文件 %.2f MB）", (double)fileSize / (1024.0 * 1024.0));
    }

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

    // 爆发流地板：距上次播放不足 1.7 秒则跳过（用户实测的快速 dismiss+再召唤间隔）
    if (ssLastPlayTime > 0 && (now - ssLastPlayTime) < kSSBurstFloor) {
        SSLog(@"爆发流跳过（距上次播放 %.2fs < 1.7s）", now - ssLastPlayTime);
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
            // 注意：不重置 ssLastPlayTime —— 让 1.7s 爆发流地板持续生效，
            // 这样关掉 Siri 马上再召唤（1.7s 内）不会重复响。
            // 正常会话（>1.7s）再次召唤时地板自然放行。
            SSLog(@"会话结束（实例计数 →0，1.7s 地板保留）");
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
    SSLog(@"v1.1.4 已加载到进程: %@ (%@)",
          [[NSProcessInfo processInfo] processName],
          [[NSBundle mainBundle] bundleIdentifier]);
}
