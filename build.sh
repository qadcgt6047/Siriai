#!/usr/bin/env bash
#
# 一键构建 Siri AI 跑马灯 (roothide .deb)
#
# 需要 macOS（完整 Xcode）或 Linux + Theos 依赖。
# 脚本会自动下载缺少的组件：roothide/theos（含子模块）、patched iOS SDK、ldid。
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

# 某些平台下 install-theos 会跳过 SDK 安装，这里补一次（已存在会自动跳过）
if ! ls "$THEOS"/sdks/iPhoneOS*.sdk >/dev/null 2>&1; then
    echo "==> 未检测到 iOS SDK，正在补装 patched SDK"
    "$THEOS/bin/install-sdk" latest
fi

echo "==> 清理旧产物"
make clean || true

echo "==> 编译并打包 (THEOS_PACKAGE_SCHEME=roothide)"
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1

echo "==> 完成，产物："
ls -lh packages/*.deb
