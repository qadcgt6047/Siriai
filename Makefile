# SiriSound —— Siri 启动音效 (rootless / arm64)
# 构建：make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
# 需要 roothide/theos，见 build.sh

TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriSound

SiriSound_FILES = Tweak.x
SiriSound_FRAMEWORKS = AVFoundation Foundation

ADDITIONAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

# MP3 随包安装：rootless 模式下 Theos 会自动给 staging 路径加 /var/jb 前缀，
# 所以这里写到 Library/... 即可，最终安装到 /var/jb/Library/Application Support/SiriSound/
after-SiriSound-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/SiriSound"
	cp SiriSound.mp3 "$(THEOS_STAGING_DIR)/Library/Application Support/SiriSound/SiriSound.mp3"
