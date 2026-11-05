# Siri AI 跑马灯 —— iOS 16 / roothide
#
# 构建：make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
# 需要 roothide/theos（不是官方 theos），见 README.md
#
# 一个包里有两个 tweak 实例：
#   SiriAI      -> 只注入 SpringBoard，负责动画
#   SiriAIPrefs -> 只注入 Preferences.app，负责设置面板替换
# 之所以拆开：设置侧要子类化 PSListController，SpringBoard 进程里没有这个私有类。

TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriAI SiriAIPrefs

SiriAI_FILES = SiriAI.x
SiriAIPrefs_FILES = SiriAIPrefs.x

FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

ADDITIONAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function

# Preferences.framework 只存在于 Settings.app 进程内，且 roothide 的 SDK
# 通常不带私有框架 stub。运行期动态解析符号即可，避免链接期依赖。
SiriAIPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
