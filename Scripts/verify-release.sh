#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

fail() {
    print -u2 "错误：$1"
    exit 1
}

[[ -f VERSION ]] || fail "缺少 VERSION 文件。"
version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION 不是有效的三段版本号：$version"

marketing_versions="$(
    sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' \
        LacEditor.xcodeproj/project.pbxproj | sort -u
)"
[[ "$marketing_versions" == "$version" ]] || {
    fail "VERSION ($version) 与 Xcode MARKETING_VERSION ($marketing_versions) 不一致。"
}

build_numbers="$(
    sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' \
        LacEditor.xcodeproj/project.pbxproj | sort -u
)"
[[ "$build_numbers" =~ ^[0-9]+$ ]] || fail "Xcode 构建号不唯一或不是整数：$build_numbers"

grep -Fq "## [$version] - " CHANGELOG.md || {
    fail "CHANGELOG.md 中缺少版本 $version 的正式记录。"
}

print "验证 LacEditor $version ($build_numbers)"
plutil -lint LacEditor.xcodeproj/project.pbxproj
swift build
swift build -c release

swiftc \
    LacEditor/Models/EditorLanguage.swift \
    LacEditor/Models/EditorDocument.swift \
    LacEditor/Services/JSONFormatter.swift \
    LacEditor/Services/TextSearchService.swift \
    LacEditor/Editor/FoldService.swift \
    LacEditor/Editor/ListContinuationService.swift \
    LacEditor/Editor/LogicalLineIndex.swift \
    LacEditor/Editor/SyntaxHighlighter.swift \
    LacEditor/Preview/MarkdownRenderer.swift \
    Verification/main.swift \
    -o .build/core-verification
.build/core-verification

swiftc \
    LacEditor/Editor/FoldLayoutManager.swift \
    LacEditor/Editor/LogicalLineIndex.swift \
    Verification/FoldLayoutVerification.swift \
    -o .build/fold-layout-verification
.build/fold-layout-verification

swiftc \
    LacEditor/Editor/ListContinuationService.swift \
    LacEditor/Editor/LacTextView.swift \
    Verification/EditorInteractionVerification.swift \
    -o .build/editor-interaction-verification
.build/editor-interaction-verification

xcodebuild \
    -quiet \
    -project LacEditor.xcodeproj \
    -scheme LacEditor \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath .build/XcodeDerivedData \
    CODE_SIGNING_ALLOWED=NO \
    build

print "发布验证通过：LacEditor $version ($build_numbers)"
