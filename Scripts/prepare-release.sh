#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

fail() {
    print -u2 "错误：$1"
    exit 1
}

new_version="${1:-}"
[[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    fail "用法：./Scripts/prepare-release.sh <主版本.次版本.修订版本>"
}

release_date="$(date +%F)"
grep -Fq "## [$new_version] - $release_date" CHANGELOG.md || {
    fail "请先在 CHANGELOG.md 中添加“## [$new_version] - $release_date”及完整更新内容。"
}

current_version="$(tr -d '[:space:]' < VERSION)"
current_build="$(
    sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' \
        LacEditor.xcodeproj/project.pbxproj | sort -u
)"
[[ "$current_build" =~ ^[0-9]+$ ]] || fail "当前 Xcode 构建号无效：$current_build"

version_is_greater() {
    local -a candidate current
    candidate=(${(s:.:)1})
    current=(${(s:.:)2})
    (( candidate[1] > current[1] )) ||
        (( candidate[1] == current[1] && candidate[2] > current[2] )) ||
        (( candidate[1] == current[1] && candidate[2] == current[2] &&
            candidate[3] > current[3] ))
}

if [[ "$new_version" != "$current_version" ]]; then
    version_is_greater "$new_version" "$current_version" || {
        fail "新版本 $new_version 必须高于当前版本 $current_version。"
    }
    git rev-parse -q --verify "refs/tags/v$new_version" >/dev/null && {
        fail "Git 标签 v$new_version 已存在。"
    }

    next_build=$((current_build + 1))
    project_file="LacEditor.xcodeproj/project.pbxproj"
    NEW_MARKETING_VERSION="$new_version" /usr/bin/perl -pi -e \
        's/^(\s*MARKETING_VERSION = )[^;]+;/$1$ENV{NEW_MARKETING_VERSION};/' \
        "$project_file"
    NEW_BUILD_NUMBER="$next_build" /usr/bin/perl -pi -e \
        's/^(\s*CURRENT_PROJECT_VERSION = )[^;]+;/$1$ENV{NEW_BUILD_NUMBER};/' \
        "$project_file"
    print -r -- "$new_version" > VERSION
    plutil -lint "$project_file"
else
    print "版本号已经是 $new_version；保留构建号 $current_build。"
fi

"$SCRIPT_DIR/verify-release.sh"

print
print "发布内容已准备完成。人工确认 CHANGELOG.md 后执行："
print "  git status --short"
print "  git add <逐项确认的发布文件路径>"
print "  git commit -m \"chore(release): v$new_version\""
print "  git tag -a v$new_version -m \"LacEditor v$new_version\""
