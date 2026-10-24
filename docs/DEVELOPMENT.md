# 开发、验证与打包

## 环境与结构

需要 macOS 14+、Swift 6.0+，可使用 Xcode 或 Command Line Tools。构建依赖系统的 `xcrun`、`iconutil`、`codesign`、`plutil` 和 Python 3。无需第三方包或开发者证书即可进行本地构建。

```text
Sources/PaneFlow/          AppKit / SwiftUI、辅助功能、面板和手势
Sources/PaneFlowCore/      布局、磁吸、联动几何和窗口写入握手
Sources/PaneFlowChecks/    无需辅助功能授权的核心检查
Sources/PaneFlowPractice/  原生验收使用的独立练习应用
Resources/                主应用和练习应用的 Info.plist
scripts/                  应用构建、DMG 与源码打包
docs/                     开发、第三方来源说明与原创示意图
.github/workflows/        macOS 构建和核心检查
```

本地生成文件与源码分开：`.build/` 是 SwiftPM 缓存，`build/` 是应用和验证输出，`dist/` 是安装包与源码预览包，`.local/` 是本地工作记录。这四个目录均被 Git 忽略，不进入源码包。

## 构建

```sh
/bin/zsh scripts/build-app.sh release
open build/PaneFlow.app
```

调试构建可将 `release` 改为 `debug`。第二个参数可指定独立输出目录；验证打包脚本时建议使用它，避免替换正在使用的应用：

```sh
/bin/zsh scripts/build-app.sh release build/validation
```

脚本生成应用图标、内嵌练习应用，附带项目许可和第三方许可，完成本地 ad-hoc 签名，并检查签名和 plists。已有应用保留在所选输出目录的 `backups/bundle.*/PaneFlow.backup/bundle-contents` 中。备份采用非应用结构，避免被系统识别为另一份 PaneFlow；恢复时将 `bundle-contents` 改回 `Contents`，再将外层 `PaneFlow.backup` 改为 `PaneFlow.app`。

## 验证

```sh
swift run --disable-sandbox PaneFlowChecks
```

核心检查覆盖布局序列化、嵌套最小尺寸、负坐标显示器、磁吸滞回、共享边界、交换，以及异步窗口写入与取消。

布局管理和磁盘保存检查无需辅助功能权限，使用独立临时设置文件，覆盖更新已有配置、复制、新建、删除、草稿保留、保存失败与重载：

```sh
build/PaneFlow.app/Contents/MacOS/PaneFlow --verify-layouts build/checks/layouts.json
```

交互检查可使用隔离的布局管理预览；这个模式只保留内存草稿，不读取或改写个人设置，也不启用窗口管理手势：

```sh
build/PaneFlow.app/Contents/MacOS/PaneFlow --preview-layouts
```

检查列表切换、保存修改、另存为、还原选择，以及关闭或退出时的未保存提示。正式应用的这些入口复用同一个布局管理窗口。

界面渲染需要桌面会话，生成浅色/深色、已授权/未授权的面板、设置、布局管理页和联动分隔条 PNG：

```sh
build/PaneFlow.app/Contents/MacOS/PaneFlow --verify-interface build/checks/interface.json
```

原生检查需要辅助功能授权。先正常退出所有 PaneFlow 实例，再通过 LaunchServices 运行：

```sh
open -n -W "$PWD/build/PaneFlow.app" --args --verify-native "$PWD/build/checks/native-launchservices.json"
```

检查只创建和操作内嵌练习应用，覆盖布局 AX 回读、联动分隔条、遮挡、交换、撤销和事务回滚，结束后恢复并关闭练习窗口。拖动检查在松手前将分隔条位置与实际 AX 窗口边界比较；刷新检查要求继续使用同一批可见的分隔条窗口。读取新生成报告的 `status` 和各项 `passed`；`open` 退出 0 不代表验收通过。原生检查进程退出 77 表示权限不足。直接从终端运行可继承启动程序的权限，不能证明正常应用已获得授权。

验证时保持练习应用位于前台；前台切换会使分隔条按设计隐藏，从而影响遮挡恢复检查。出现失败时保留原报告和当时的前台应用信息，不将复测通过当作原因已修复。自动检查不模拟物理鼠标，也不代表所有第三方应用兼容；绿按钮悬停、标题拖动、磁吸手感仍需真实鼠标验证。面板还需交互检查：布局菜单选择和 Esc、外部点击、关闭按钮、自定义编辑器，以及仅用练习窗口验证成功收起和失败保留。

GitHub CI 执行构建、核心检查、布局管理保存检查、本地 DMG 与源码打包；未将需要桌面和权限的检查算作 CI 验收。

## 源码包与发布

将已构建的应用封装为可拖入“应用程序”的本地 DMG：

```sh
/bin/zsh scripts/package-dmg.sh
```

输出 `dist/PaneFlow-<版本>-<架构>.dmg`，带有 `Applications` 快捷方式和安装说明。脚本检查现有应用签名，原样复制应用，不重新编译或签名；完成后验证磁盘映像。第一个参数可指定应用路径，第二个参数可指定输出目录。当前应用为 Apple Silicon 架构，本地包尚未公证。

```sh
/bin/zsh scripts/package-source.sh
```

输出 `dist/PaneFlow-<版本>-source-preview.tar.gz`。源码采用 MIT 许可证；文件名中的 `source-preview` 表示源码归档，不代表已完成二进制公证。脚本只收录指定的源码、资源、文档、脚本、工作流和许可文件，清除归档中的本地用户/组信息。发布前从解压后的源码重新构建，核对许可与版本，并检查待发布文件。

本地签名应用重新构建后，macOS 可能要求重新授权。签名、公证和二进制正式发布由维护者另行配置；项目没有自动发布任务。
