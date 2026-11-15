# SiriSound Theos Makefile
# 编译 arm64e Siri 启动音效插件

TARGET := iphone:clang:latest:16.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriSound
SiriSound_FILES = Tweak.x
SiriSound_FRAMEWORKS = AudioToolbox Foundation
SiriSound_CFLAGS = -fobjc-arc -O2

include $(THEOS_MAKE_PATH)/tweak.mk

# 把 MP3 一起打包
after-SiriSound-stage::
	mkdir -p $(THEOS_STAGING_DIR)/var/jb/Library/Application\ Support/SiriSound
	cp SiriSound.mp3 $(THEOS_STAGING_DIR)/var/jb/Library/Application\ Support/SiriSound/SiriSound.mp3
