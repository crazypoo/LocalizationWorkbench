# 构建和验证记录

## 本次实际验证

- 环境：Debian 13, Swift 6.2.1 Linux x86_64。
- 命令：`swift test -q`，覆盖 Foundation `LocalizationCore`、事务写入与 CLI 编译。
- 通过的 XCTest：22 / 22（结果记录在 `TEST_RESULTS.txt`）。
- CLI 命令：`localization-workbench scan Samples` 和 `validate Samples` 运行成功，示例包含一个预期的缺失翻译警告。
- GUI 文件：`swiftc -frontend -parse Sources/LocalizationWorkbenchApp/LocalizationWorkbenchApp.swift` 语法检查通过。

## macOS 上必要的最终验证

1. `xcodebuild -version`，确认使用完整 Xcode。
2. Xcode 打开项目，编译 `LocalizationWorkbenchApp`。如果 Apple SDK 调整导致个别 SwiftUI 修饰符类型检查失败，应以 Xcode 的真实诊断为准；Linux 不具备完整 macOS GUI 构建链。
3. `./scripts/build_app.sh` 封装 `.app` 并启动。
4. GUI 打开 `Samples`：左侧应出现 Catalog/Legacy 两类项目，右侧矩阵含 en 与 zh-Hans。
5. 复制 `Samples` 到临时文件夹，在 GUI 更改 `.strings` 已有值，点击 Review 检查 diff、备份和保存结果。
6. 对 `.xcstrings` 新建 `variations/device/iphone`，检查修改前后的 JSON 元数据；对 `.stringsdict` 新建 plural，检查 `other` 分支。
7. 在 Xcode 同时修改资源文件，确保保存前出现外部文件冲突提示并要求重新扫描。
8. 如需正式分发他人，配置自己的 Bundle ID、Developer ID 签名与 notarization。
