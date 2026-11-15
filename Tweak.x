// SiriSound - Siri 启动音效插件 (roothide / arm64e)
// RootHide Bootstrap / iPhone XR / iOS 16.0.2
//
// hook SiriUIBackgroundBlurViewController（原版 LiquidSiri 在同一设备上
// 验证过此类的存在），Siri 界面出现时播放 MP3，消失时停止。

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static AVAudioPlayer *ssPlayer = nil;

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
    NSString *path = @"/var/jb/Library/Application Support/SiriSound/SiriSound.mp3";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        SSLog(@"MP3 不存在: %@", path);
        return;
    }

    NSError *err = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                              error:&err];
    if (!p) {
        SSLog(@"AVAudioPlayer 初始化失败: %@", err);
        return;
    }
    [p setNumberOfLoops:0];
    [p prepareToPlay];
    BOOL ok = [p play];
    SSLog(@"播放开始 ok=%d 时长=%.2fs", ok, p.duration);
    ssPlayer = p;
}

static void SSStopSound(void) {
    if (ssPlayer) {
        [ssPlayer stop];
        ssPlayer = nil;
        SSLog(@"播放停止");
    }
}

%hook SiriUIBackgroundBlurViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewDidAppear");
    SSPlaySound();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SSLog(@"SiriUIBackgroundBlurViewController viewDidDisappear");
    SSStopSound();
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
    SSStopSound();
}

%end

%ctor {
    SSLog(@"已加载到进程: %@ (%@)",
          [[NSProcessInfo processInfo] processName],
          [[NSBundle mainBundle] bundleIdentifier]);
}
