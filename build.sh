#!/usr/bin/env bash
#
# 一键构建 SiriSound (roothide arm64e .deb)
# 在 GitHub Actions 的 macOS 运行器上执行。
#
set -euo pipefail
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"

if [ ! -d "$THEOS/.git" ]; then
    echo "==> 未检测到 roothide/theos，正在安装到 $THEOS"
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
else
    echo "==> 使用已有 Theos: $THEOS"
fi
export PATH="$THEOS/bin:$PATH"

if ! ls "$THEOS"/sdks/iPhoneOS*.sdk >/dev/null 2>&1; then
    echo "==> 未检测到 iOS SDK，正在补装 patched SDK"
    "$THEOS/bin/install-sdk" latest
fi

# 从 base64 还原 MP3（避免二进制文件直接进 git）
if [ -f SiriSound.mp3.b64 ] && [ ! -f SiriSound.mp3 ]; then
    echo "==> 解码 SiriSound.mp3"
    python3 -c "import base64,sys; open('SiriSound.mp3','wb').write(base64.b64decode(open('SiriSound.mp3.b64').read().strip()))"
    ls -la SiriSound.mp3
fi

echo "==> 清理旧产物"
make clean || true

echo "==> 编译并打包 (THEOS_PACKAGE_SCHEME=roothide)"
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1

echo "==> 完成，产物："
ls -lh packages/*.deb
