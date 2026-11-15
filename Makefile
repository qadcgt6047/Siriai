# SiriSound —— Siri 启动音效 (roothide / arm64e)
# 构建：make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
# 需要 roothide/theos，见 build.sh

TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriSound

SiriSound_FILES = Tweak.x
SiriSound_FRAMEWORKS = AudioToolbox Foundation

ADDITIONAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

# 音效随包安装到 roothide 的 /var/jb 路径（CAF 格式，由 build.sh 转换）
after-SiriSound-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/Application Support/SiriSound"
	cp SiriSound.caf "$(THEOS_STAGING_DIR)/var/jb/Library/Application Support/SiriSound/SiriSound.caf"
