#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h:A}"

fail() {
    print -u2 "错误：$1"
    exit 1
}

[[ -f "$PROJECT_ROOT/VERSION" ]] || fail "目标不是 LacEditor 工程。"
[[ -d "$PROJECT_ROOT/LacEditor.xcodeproj" ]] || fail "缺少 LacEditor.xcodeproj。"
[[ "$PROJECT_ROOT" != "/" && "$PROJECT_ROOT" != "$HOME" ]] \
    || fail "拒绝清理过宽的目录：$PROJECT_ROOT"

targets=(
    "$PROJECT_ROOT/.build"
    "$PROJECT_ROOT/.swiftpm"
    "$PROJECT_ROOT/build"
    "$PROJECT_ROOT/DerivedData"
)

existing_targets=()
total_kib=0
for target in $targets; do
    [[ -e "$target" ]] || continue
    [[ "${target:h:A}" == "$PROJECT_ROOT" ]] \
        || fail "清理目标越出工程根目录：$target"
    [[ "${target:t}" == ".build" || "${target:t}" == ".swiftpm" \
        || "${target:t}" == "build" || "${target:t}" == "DerivedData" ]] \
        || fail "目标不在构建产物白名单：$target"
    existing_targets+=("$target")
    size_kib="$(du -sk "$target" | awk '{print $1}')"
    (( total_kib += size_kib ))
done

if (( ${#existing_targets} == 0 )); then
    print "没有可清理的项目构建产物。"
    exit 0
fi

print "LacEditor 构建产物清理预览"
print "工程：$PROJECT_ROOT"
print "预计释放：$(awk -v kib="$total_kib" 'BEGIN { printf "%.2f GiB", kib / 1024 / 1024 }')"
print
for target in $existing_targets; do
    print "  $(du -sh "$target" | awk '{print $1}')  $target"
done

if [[ "${1:-}" != "--confirm" || "${2:-}" != "$PROJECT_ROOT" ]]; then
    print
    print "当前仅预览，没有删除任何文件。"
    print "确认以上绝对路径后执行："
    print "  ./Scripts/clean-build-artifacts.sh --confirm '$PROJECT_ROOT'"
    exit 0
fi

(( $# == 2 )) || fail "确认模式不接受其他参数。"

for target in $existing_targets; do
    /bin/rm -rf -- "$target"
    print "已清理：$target"
done

print "构建产物清理完成。源码、Package.resolved、Xcode 工程和 Design 均未处理。"
