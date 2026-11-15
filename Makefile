# SiriSound —— Siri 启动音效 (roothide / arm64e)
# 构建：make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
# 需要 roothide/theos，见 build.sh

TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriSound

SiriSound_FILES = Tweak.x
SiriSound_FRAMEWORKS = AVFoundation Foundation

ADDITIONAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

# MP3 随包安装到 roothide 的 /var/jb 路径
after-SiriSound-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/Application Support/SiriSound"
	cp SiriSound.mp3 "$(THEOS_STAGING_DIR)/var/jb/Library/Application Support/SiriSound/SiriSound.mp3"
