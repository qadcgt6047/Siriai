# Siri AI 跑马灯 · iOS 16.0.2 / roothide

在 **iOS 16** 上复刻 Apple Intelligence / 新版 Siri 的屏幕边缘彩色流光「跑马灯」，
并把**设置里系统的「Siri 与搜索」控制项替换**成插件自己的设置面板。

> 目标环境：iOS 16.0.2 + Dopamine **roothide**（arm64e）。
> 工程按 roothide 规范打包（`THEOS_PACKAGE_SCHEME=roothide`，`Architecture: iphoneos-arm64e`）。

---

## 一、它做了什么

| 部分 | 说明 |
| --- | --- |
| 边缘流光 | `CAGradientLayer` 的 **conic（圆锥）渐变** 匀速旋转，用圆角矩形描边 `CAShapeLayer` 做遮罩，得到沿屏幕边框循环跑动的彩色光带；外层再叠一圈宽描边低透明度做辉光 |
| 呼吸/律动 | 光带透明度轻微起伏，配合 Siri 唤醒时的「聆听」感 |
| 跑马灯文字 | 屏幕底部半透明胶囊内，两段相同文字首尾相接无缝横向滚动（可改文字、速度、开关） |
| 声波条 | 胶囊左侧 7 根柱状条错相位缩放，模拟 AI 波形 |
| 设置替换 | 设置根列表里的 Siri 项改名为「Siri AI」并接管点击 → 打开本插件面板；面板内保留「系统 Siri 与搜索」入口，可回到原生设置 |
| 备用入口 | 万一某个固件的 Siri 项命名不同，设置根列表底部仍会自动插入一个「跑马灯设置」链接 |
| 热更新 | 设置改动通过 Darwin 通知即时推送到 SpringBoard，不需要 Respring |

**它只做绘制**：不改动 Siri 的语音识别、听写、音频路由，也不注入任何 App。

---

## 二、目录结构

```
SiriAI16/
├── Makefile                 # 两个 tweak 实例，共用一个 .deb
├── control                  # deb 元数据
├── SiriAI.plist             # Filter: com.apple.springboard
├── SiriAIPrefs.plist        # Filter: com.apple.Preferences
├── SAIACommon.h             # 配置默认值 / plist 读写 / 配色（两个 dylib 共用）
├── SiriAI.x                # SpringBoard：检测 Siri 出现/消失 + 动画绘制
├── SiriAIPrefs.x           # Settings：替换 Siri 控制项 + 自定义 PSListController 面板
├── PrefsShims.h             # Preferences.framework 私有类的最小声明
├── build.sh                 # 自动下载 roothide/theos + SDK 并编译
├── .github/workflows/build.yml  # macOS CI，推送后自动产出 .deb
└── README.md
```

### 为什么要拆成两个 dylib

`SiriAIPrefs` 需要子类化 `PSListController`（Preferences.framework 私有类），
这个框架**只在 Settings.app 进程里加载**。如果把它编进注入 SpringBoard 的 dylib，
SpringBoard 启动时类注册会因为找不到父类而出问题。因此：

- `SiriAI.dylib` → 只注入 SpringBoard，纯 UIKit / QuartzCore；
- `SiriAIPrefs.dylib` → 只注入 `com.apple.Preferences`，用
  `-Wl,-undefined,dynamic_lookup` 在运行时解析私有类，不需要私有框架 stub。

### 为什么不用 PreferenceBundle

roothide 的 jbroot 是**每次越狱随机目录**，系统 API 用字面量
`/Library/PreferenceBundles/...` 是找不到的（需要用 `jbroot()` 转换）。
本工程的设置面板**完全由代码构造 `PSSpecifier`**，不加载任何 bundle、不读取任何
插件资源文件，因此天然规避了路径问题。配置 plist 也放在
`NSHomeDirectory()/Library/Preferences/`（SpringBoard 与设置 App 同为 mobile 用户），
三种越狱方案下路径都一致。

---

## 三、构建（Windows 也能出 .deb）

> **没有 macOS / Linux 电脑？直接用「方式 B」。**
> GitHub Actions 跑的是**GitHub 自己在云端的 macOS 主机**（`macos-14`，自带完整 Xcode），
> 编译过程完全不经过你的电脑。Windows 上只需要：一个浏览器 + 一个 GitHub 账号。
> 上传源码 → 等约 5～15 分钟 → 网页上直接下载编译好的 `.deb`。
>
> 本机（Windows + MINGW）缺 clang / make / ldid / iOS SDK，WSL 又被策略禁用，
> 所以**这里产不出已签名的包**；缺的工具链已由 `build.sh` 和 CI 自动下载补齐。

### 方式 A：本机 macOS / Linux（如果你有）

```bash
cd SiriAI16
chmod +x build.sh
./build.sh
```

脚本会：安装 **roothide/theos**（递归拉子模块）→ 补装 patched iOS SDK →
`make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1`。
产物：`packages/com.siriai16.tweak_1.0.0_iphoneos-arm64e.deb`。

> 必须用 **roothide 分支的 Theos**，官方 Theos 不认识 `THEOS_PACKAGE_SCHEME=roothide`。
> 若 `arm64e` 编译失败，改用 `make package ARCHS=arm64 ...`。

### 方式 B：纯浏览器 · 零本地环境（推荐）

**第 1 步｜建仓库**
打开 `github.com` 登录 → 右上角 `+` → `New repository` →
名字填 `SiriAI16`，选 **Public**（公开仓库 Actions 免费；工程里没有任何个人信息）→ `Create repository`。

**第 2 步｜上传源码**
把 `SiriAI16-for-GitHub.zip` 解压，**进入解压出来的文件夹**，点
`Add file` → `Upload files`，把解压出来的**所有文件连同 `.github` 文件夹一起**拖进上传框
→ 拉到底 `Commit changes`。

> ⚠️ `.github` 文件夹一定要一起上传（Windows 里它是普通可见文件夹），里面是编译脚本；
> 少了它 Actions 不会启动。
> 若拖拽文件夹没保留目录：改为在仓库 `Actions` → `set up a workflow yourself`，
> 把 `build.yml` 的内容整段粘进去，文件名保持 `.github/workflows/build.yml` → 提交，
> 再单独上传其余源码文件。

**第 3 步｜等编译**
提交后 `Actions` 页会出现一个黄色圆点的 `Build SiriAI16 roothide deb`，
点进去可以实时看日志。首次约 5～15 分钟（要下载 Theos 和 iOS SDK）。
也可以随时在这里点 `Run workflow` 手动重新构建。

**第 4 步｜下载成品**
构建变绿后，二选一：

- 仓库右侧 **Releases** → 最新一条 `SiriAI16 build N` → 直接下载 `.deb`（已自动发布）；
- 或 `Actions` → 该次运行 → 底部 `Artifacts` → `SiriAI16-roothide`（下载是 zip，解压出 deb）。

**第 5 步｜装到手机**（任选其一）

| 办法 | 操作 |
| --- | --- |
| 最省事 | 用微信/QQ 把 `.deb` 传到手机 → 用 **Filza** 打开 → 交给 Sileo/Zebra 安装 |
| Sileo / Zebra | 把 deb 放进 `/var/mobile/Documents/`，在包管理器里导入 |
| Windows 终端 | `scp xxx.deb mobile@手机IP:/var/mobile/Documents/` 然后 `ssh mobile@手机IP` 执行 `dpkg -i ...` |

装完 `killall -9 SpringBoard`。详见下一节。

### 方式 C：连 GitHub 都不方便时

| 备选 | 说明 |
| --- | --- |
| **GitHub Codespaces** | 同一个 GitHub 账号，浏览器里开一台云端 Linux；Theos 原生支持 Linux，在终端跑一次 `./build.sh` 即可，产物可直接下载。适合 Actions 被限制时 |
| **在越狱手机上编译** | roothide 自带 Procursus/apt，可装 `clang make ldid dpkg-dev` + roothide Theos 在设备本地编译。属进阶玩法：占几百 MB 空间、clang 在 iOS 上需要签名权限，不保证一次成功 |
| **找人代编译** | 把 `SiriAI16-for-GitHub.zip` 发给有 Mac 的朋友，解压后 `./build.sh`，把 `packages/*.deb` 发回给你即可，全程一条命令 |

> 不建议在 Windows 本机硬凑交叉编译工具链：需要 LLVM/Clang 的 Mach-O 链接器、
> patched iOS SDK、Logos 的 Perl 运行时、`ldid` 签名器和 `dpkg-deb`，
> 任何一环缺失都只能产出无法安装的包，成本远高于云端点一下。

---

## 四、安装

```bash
# 设备上（roothide 的 bootstrap 以 jbroot 为根，路径照写即可）
dpkg -i com.siriai16.tweak_1.0.0_iphoneos-arm64e.deb
killall -9 SpringBoard
```

或者用 Sileo / Zebra 直接打开 deb 安装。

> roothide 注意：**务必走 `dpkg -i`**，不要手工把 dylib 拷进 TweakInject 目录。
> dpkg 安装时会为含 Mach-O 的目录生成 `.jbroot` 符号链接，手工拷贝会导致
> 依赖路径没被 patch、SpringBoard 被 `dyld: Invalid Page` 杀掉。

安装后打开 **设置 → Siri AI**（原「Siri 与搜索」位置），
先点「预览 5 秒」看效果，再调参数。原来的系统 Siri 设置在面板底部的
「系统 Siri 与搜索」。

---

## 五、可配置项

| 分类 | 项目 |
| --- | --- |
| 基本 | 启用动画、预览 5 秒、立即停止 |
| 外观 | 配色（Apple Intelligence / 极光 / 霓虹 / 银白）、旋转速度、光带宽度、辉光强度、圆角半径 |
| 跑马灯 | 显示开关、声波条、文字内容、滚动速度 |
| 高级 | 是否替换系统 Siri 项、控制项显示名称、最长显示时间、Siri 界面类名关键字 |
| 系统 | 跳转原生 Siri 设置、恢复默认 |

---

## 六、Siri 唤醒是怎么被检测到的

三层冗余，避免不同 16.x 小版本类名差异导致失效：

1. **主路径**：hook `UIViewController` 的 `viewDidAppear:` / `viewWillDisappear:` /
   `viewDidDisappear:`，按类名关键字（`Siri` / `Assistant` / `AFUI` / `SiriPresentation` …
   可在设置里改）判断是不是 Siri 界面，用弱引用 `NSHashTable` 记录当前可见的 Siri VC，
   全部消失才收起动画。
2. **兜底**：每 0.6s 轮询 `SBAssistantController +isVisible`（类不存在就自动跳过），
   即使 VC hook 没命中也能把动画拉起来。
3. **手动**：设置面板的预览 / 停止按钮通过 Darwin 通知直接控制。

覆盖层是一个独立的、高 `windowLevel`、全透明且 `userInteractionEnabled = NO` 的
`UIWindow`（挂在 `UIWindowScene` 上以正确响应旋转），不吃触摸、不抢 keyWindow。

---

## 七、排错

| 现象 | 处理 |
| --- | --- |
| **Actions 页停在「开始使用 GitHub Actions」引导页，没有任何构建** | 说明仓库里没有 `.github/workflows/`。最常见是**把 zip 压缩包整个拖进上传框了**（GitHub 网页不会自动解压），或漏传 `.github` 文件夹。先去「代码」页看文件列表：如果只看到一个 `.zip`，删掉它，解压后按方式 B 第 2 步重新上传里面的 12 个文件 + `.github` 文件夹；也可以点引导页蓝色「跳过此项」链接，手动粘贴 workflow（见下条） |
| 引导页里的模板该选哪个 | **都不要点「配置」**。`Xcode - 构建与分析`、`用 Make 构建项目` 是普通 Xcode/Make 项目的模板，不认识 Theos 的 roothide 打包规则。要么上传现成的 workflow，要么点「跳过此项」自己粘贴 |
| 手动创建 workflow 怎么操作 | 引导页点蓝色「跳过此项，且 →」→ 编辑器里 Ctrl+A 清空默认模板 → 粘贴 `build.yml` 全文 → 顶部文件名填 `.github/workflows/build.yml` → `Commit changes`。之后仍要把其余源码上传，再在 Actions 页点 `Run workflow` |
| 安装后设置里没变化 | 确认 `SiriAIPrefs.dylib` + `SiriAIPrefs.plist` 都在；杀掉 Settings 重开；检查 `com.apple.Preferences` 过滤是否生效 |
| 唤醒 Siri 没有动画 | 先在设置里点「预览 5 秒」；能显示说明绘制没问题，只是检测没命中 → 在「Siri 界面类名关键字」里加类名，或依赖轮询兜底 |
| 动画不消失 | 「最长显示时间」设成 30 秒之类；或点「立即停止」 |
| 想恢复原生 Siri 项 | 设置面板里关掉「替换系统 Siri 控制项」，再重开设置 App |
| SpringBoard 安全模式 | 卸载本包；检查是否手工拷贝过 dylib（见上文 roothide 注意事项） |
| 编译报 `PSListController` 未定义 | 说明用的不是 ARC / 缺 `-Wl,-undefined,dynamic_lookup`，检查 Makefile；仍需 `#import "PrefsShims.h"` |
| 编译报找不到 SDK | `install-theos` 的 `install-sdk latest` 没跑成功，手动执行 `$THEOS/bin/install-sdk latest` |

---

## 八、已知限制

- 动画是**视觉复刻**，不是真的 Apple Intelligence / 新版 Siri；没有 LLM 能力。
- 圆锥渐变在刘海/灵动岛区域会被系统 UI 自然遮挡，属正常表现。
- 设置项标题改名需要**重开设置 App**才会刷新（列表在首次加载时缓存）。
- 定位系统 Siri 项依赖其 specifier 里含 `siri` 字样（id / bundle / label / detail），
  极个别区域/语言若全部被本地化覆盖，请用根列表底部的「跑马灯设置」备用入口，
  并把缺失的关键字补进配置。
- 只在 iOS 16 系列验证设计；iOS 17+ 的 Siri 呈现链路变化较大，需要重新核对类名。

---

## 九、参考

- roothide 官方开发者文档：`https://github.com/roothide/Developer`
  （`roothide.md` / `interface.md` / `entitlements.md`）
- roothide Theos：`https://github.com/roothide/theos`
- Apple Intelligence 配色参考：`#BC82F3 #F5B9EA #8D9FFF #AA6EEE #FF6778 #FFBA71 #C686FF`
