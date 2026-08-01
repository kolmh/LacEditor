#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

fail() {
    print -u2 "验收失败：$1"
    exit 1
}

print "[1/5] 发布门禁与静态分析"
"$SCRIPT_DIR/verify-release.sh"
xcodebuild \
    -quiet \
    -project LacEditor.xcodeproj \
    -scheme LacEditor \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath .build/XcodeDerivedData \
    CODE_SIGNING_ALLOWED=NO \
    analyze

print "[2/5] 文件读写与格式集成验证"
swiftc \
    LacEditor/Models/EditorLanguage.swift \
    LacEditor/Models/FileTreeNode.swift \
    LacEditor/Services/FileService.swift \
    Verification/FileServiceVerification.swift \
    -o .build/file-service-verification
.build/file-service-verification

print "[3/5] 大文件性能基线"
swiftc -O \
    LacEditor/Models/EditorLanguage.swift \
    LacEditor/Services/TextSearchService.swift \
    LacEditor/Editor/LogicalLineIndex.swift \
    LacEditor/Editor/SyntaxHighlighter.swift \
    LacEditor/Preview/MarkdownRenderer.swift \
    Verification/PerformanceVerification.swift \
    -o .build/performance-verification
.build/performance-verification

print "[4/5] 产物、平台与隐私静态检查"
app_path=".build/XcodeDerivedData/Build/Products/Release/LacEditor.app"
info_plist="$app_path/Contents/Info.plist"
binary="$app_path/Contents/MacOS/LacEditor"
[[ -d "$app_path" ]] || fail "缺少 Release App 产物。"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")" == "14.0" ]] \
    || fail "最低系统版本不是 macOS 14.0。"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" \
    == "$(tr -d '[:space:]' < VERSION)" ]] || fail "App 产物版本与 VERSION 不一致。"
architectures="$(lipo -archs "$binary")"
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] \
    || fail "Release App 不是 arm64 + x86_64 双架构。"

for size in 16 32 128 256 512; do
    icon_1x="LacEditor/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}.png"
    icon_2x="LacEditor/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@2x.png"
    [[ -f "$icon_1x" ]] \
        || fail "缺少 ${size}x${size} App 图标。"
    [[ -f "$icon_2x" ]] \
        || fail "缺少 ${size}x${size}@2x App 图标。"
    [[ "$(sips -g pixelWidth "$icon_1x" | tail -1 | awk '{print $2}')" == "$size" ]] \
        || fail "${size}x${size} App 图标像素尺寸错误。"
    [[ "$(sips -g pixelWidth "$icon_2x" | tail -1 | awk '{print $2}')" == "$((size * 2))" ]] \
        || fail "${size}x${size}@2x App 图标像素尺寸错误。"
done

if rg -n 'URLSession|NWConnection|import Network|com\.apple\.security\.network' \
    LacEditor LacEditor.xcodeproj Package.swift >/dev/null; then
    fail "源码或工程中发现未审核的网络 API/权限。"
fi

print "[5/5] 构建隔离的 UI 验收 App"
xcodebuild \
    -project LacEditor.xcodeproj \
    -scheme LacEditor \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath .build/AcceptanceDerivedData \
    PRODUCT_BUNDLE_IDENTIFIER=com.laceditor.acceptance \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

acceptance_app=".build/AcceptanceDerivedData/Build/Products/Release/LacEditor.app"
[[ -d "$acceptance_app" ]] || fail "隔离 UI 验收 App 构建失败。"
print
print "自动化验收通过。UI 验收 App：$acceptance_app"
