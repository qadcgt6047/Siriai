# SiriSound v1.1.0 —— Siri 启动音效 (rootless / arm64)
# 构建：make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
# 见 build.sh

TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriSound

SiriSound_FILES = Tweak.x
SiriSound_FRAMEWORKS = AudioToolbox Foundation

ADDITIONAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

# 音效随包安装：rootless 模式下 Theos 会自动给 staging 路径加 /var/jb 前缀，
# 所以这里写到 Library/... 即可，最终安装到 /var/jb/Library/Application Support/SiriSound/
# （音效为 CAF 格式，由 build.sh 用 afconvert 从 MP3 转换，供系统提示音通道使用）
after-SiriSound-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/SiriSound"
	cp SiriSound.caf "$(THEOS_STAGING_DIR)/Library/Application Support/SiriSound/SiriSound.caf"
