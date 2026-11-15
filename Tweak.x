// SiriSound v1.1.0 - Siri 启动音效插件 (rootless / arm64)
// iPhone XR / iOS 16.0.2
//
// v1.1.0 修复（依据设备 debug.txt 日志）：
//  1. 播放多次：iOS 16 一次 Siri 会话会连续触发 viewDidAppear 3-4 次
//     （Siri UI 内部重建控制器），加 5 秒防抖窗口，一次会话只播一次。
//  2. Siri 直接下线：v1.0.0 的 AVAudioPlayer 会通过 AVAudioSession
//     抢占 Siri 的录音会话（Siri UI 与本插件同在 SpringBoard 进程内），
//     导致 Siri 录音被打断后自动退出。改用 AudioServicesPlaySystemSound
//     系统提示音通道（键盘音/原生 Siri 提示音同款通道），完全不经过
//     AVAudioSession，绝不打断录音。

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

static SystemSoundID ssSoundID = 0;
static NSTimeInterval ssLastPlayTime = 0;

// 防抖窗口：一次 Siri 会话内重复触发的 viewDidAppear 都在几秒内，
// 5 秒窗口足够覆盖；Siri 退出后再次召唤间隔通常超过 5 秒。
static const NSTimeInterval kSSDebounceInterval = 5.0;

static void SSLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[SiriSound] %@\n", msg];
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
    // 防抖：窗口内只播放一次（iOS 16 一次 Siri 会话会多次触发 viewDidAppear）
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (ssLastPlayTime > 0 && (now - ssLastPlayTime) < kSSDebounceInterval) {
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
    SSLog(@"播放（系统提示音通道，不打断录音）");
}

%hook SiriUIBackgroundBlurViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewDidAppear");
    SSPlaySound();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    // Siri 界面消失：重置防抖，下次召唤可立即播放。
    // 不需要停止播放——音效约 2 秒，走系统提示音通道会自然播完。
    SSLog(@"SiriUIBackgroundBlurViewController viewDidDisappear（重置防抖）");
    ssLastPlayTime = 0;
}

%end

%hook SiriUIContentViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIContentViewController viewDidAppear");
    SSPlaySound();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIContentViewController viewDidDisappear（重置防抖）");
    ssLastPlayTime = 0;
}

%end

%ctor {
    SSLog(@"v1.1.0 已加载到进程: %@ (%@)",
          [[NSProcessInfo processInfo] processName],
          [[NSBundle mainBundle] bundleIdentifier]);
}
