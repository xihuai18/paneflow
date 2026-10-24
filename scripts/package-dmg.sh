#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
(( $# <= 2 )) || { print -u2 'Usage: scripts/package-dmg.sh [app-path] [output-directory]'; exit 2; }
app_path="${1:-$project_root/build/PaneFlow.app}"
output_dir="${2:-$project_root/dist}"
app_path="${app_path:A}"
output_dir="${output_dir:A}"
/usr/bin/codesign --verify --deep --strict "$app_path"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
architecture="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/PaneFlow")"
[[ "$architecture" != *' '* ]] || architecture=universal
mkdir -p "$output_dir" "$project_root/build/packaging"
stage="$(mktemp -d "$project_root/build/packaging/dmg.XXXXXX")"
retain_stage() {
  if [[ -d "$stage/PaneFlow.app/Contents" ]]; then
    mv "$stage/PaneFlow.app/Contents" "$stage/PaneFlow.app/bundle-contents"
    mv "$stage/PaneFlow.app" "$stage/PaneFlow.packaged-artifact"
  fi
}
trap retain_stage EXIT
/usr/bin/ditto "$app_path" "$stage/PaneFlow.app"
/usr/bin/codesign --verify --deep --strict "$stage/PaneFlow.app"
ln -s /Applications "$stage/Applications"
mkdir -p "$stage/docs"
cp "$project_root/LICENSE" "$project_root/LICENSE-STATUS.md" "$project_root/NOTICE-PaneGrid" "$stage/"
cp "$project_root/docs/THIRD_PARTY.md" "$stage/docs/"
cat > "$stage/安装说明.txt" <<'TXT'
窗合 PaneFlow

1. 如果 PaneFlow 正在运行，先从菜单栏退出。
2. 将 PaneFlow.app 拖到旁边的 Applications 文件夹。
3. 从“应用程序”打开 PaneFlow。
4. 在设置中查看辅助功能状态；若未允许，按提示在系统设置中添加并允许应用程序文件夹里的 PaneFlow。
5. 安装完成后推出此磁盘映像。

需要 macOS 14 或更新版本。
此安装包用于本地测试，使用 ad-hoc 签名，尚未经过 Apple 公证。
项目采用 MIT 许可证；第三方许可见 NOTICE-PaneGrid。
TXT
destination="$output_dir/PaneFlow-$version-$architecture.dmg"
/usr/bin/hdiutil create -ov -volname PaneFlow -srcfolder "$stage" -format UDZO "$destination"
/usr/bin/hdiutil verify "$destination"
print "Packaged: $destination"
