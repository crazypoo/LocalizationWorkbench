# Localization Workbench 1.0

一个**原生 macOS 多语言管理工具**，支持 Apple `.strings`、`.stringsdict`、`.xcstrings`，结合 Stringz 的「左侧文件/完成率 + 横向翻译矩阵」交互思路，以及 iOSLocalizationEditor 的并排翻译、缺失高亮体验。独立实现，没有复制任何第三方项目的 UI 资源或 GPL 源码。

> **交付形式：可编译的完整 Swift Package 源码（GUI + Foundation 核心 + CLI + 22 个自动化测试 + 示例资源 + macOS `.app` 打包脚本）。** 当前执行环境为 Linux，已实测 `swift test` 全部通过、CLI `scan/validate` 可运行，GUI 源码通过 Swift 语法解析；**未在 macOS/Xcode 上进行最终 GUI 编译及启动验证**。因此这里不声称已产出经 Mac 实机验证的 `.app`。

## 1. 环境与启动

推荐：Apple Silicon Mac、macOS 14 或以上、完整 Xcode 及其 Command Line Tools。

**方法 A：在 Xcode 运行**

1. 解压 ZIP，双击/用 Xcode 打开包含 `Package.swift` 的工程文件夹。
2. 选择 **LocalizationWorkbenchApp** executable Scheme，运行目标为 **My Mac**。
3. 按 **⌘O**，选 iOS/macOS 项目根目录、`.xcodeproj` 或 `.xcworkspace`，也可以先选择随包附带的 `Samples/`。
4. 在左侧选资源组，在中央表格直接编辑某种语言，或者在右侧 Inspector 编辑所选 Key。
5. 点击 **Stage edits** 暂存，再点击 **Review & Save** 预览每个文件的前后内容，确认后保存。**保存前仍建议保持 Git 工作树干净。**

**方法 B：在 Mac 生成双击运行的 `.app`**

```bash
cd LocalizationWorkbench_1.0
./scripts/build_app.sh
open dist/LocalizationWorkbench.app
```

脚本将 `LocalizationWorkbenchApp` Release 二进制封装为本机应用并作临时 ad-hoc 签名，不需要付费开发者账号。**不是用于公开分发的 Developer ID 签名或 Apple notarization**。若 Xcode 不是默认开发目录，可以先执行：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 2. 已包含功能

| 分类 | 功能 |
| --- | --- |
| 文件查找 | 目录、`.xcodeproj`、`.xcworkspace` 根目录扫描，跳过 Pods/build/.build/Carthage/DerivedData 等目录 |
| 三种文件 | `.strings`（UTF-8）、`.stringsdict`（XML/binary plist）、`.xcstrings`（JSON catalogs） |
| Stringz 风格界面 | 文件格式分组、左侧项目资源列表、完成度进度、右侧多语言翻译矩阵、Inspector、深浅色自适应 |
| 基础编辑 | 多语言并排搜索、翻译直接输入、缺失过滤、警告过滤、批量暂存、撤销/重做**已暂存的操作** |
| 条目管理 | 新增 Key、跨语言重命名 Key、删除 Key、插入/更新翻译注释、增设语言 |
| 变体 | `.xcstrings` 现有与新增 plural/device 变体；`.stringsdict` 复数规则及已有变体编辑、创建规范的 plural `other` 规则 |
| 格式校验 | 缺失翻译、重复 `.strings` Key、重复 JSON 对象 Key、常见 printf 占位符不一致、缺少必需的 `other` 复数形式 |
| 导入导出 | CSV 文件导出 / 导入（包含带逗号、引号、换行的翻译）；导入变更可审阅后提交 |
| 安全保存 | 暂存内存编辑、逐文件前后预览、外部修改检查、按批次备份、相对路径备份清单、原子写回、失败时尽力回滚 |
| CLI / CI | `scan`、`validate --strict`、`export`、`import --write` |
| 测试 | 22 项 `swift test` 核心测试（包括批量保存、冲突检测、JSON 元数据、翻译导出、复数规则） |

### 文件写回策略

- **`.strings`**：对于已有 Key 的翻译采用目标 Value 字节范围替换，保留其他字符、注释、顺序和换行；新增/改名/删除 Key 也是局部编辑。
- **`.xcstrings`**：已存在的 `stringUnit.value` 使用 JSON token 范围定点修改；如果原 `state` 为 `new`，同时设为 `translated`。新增语言/Key/变体或修改注释属于结构变更，会使用 JSON 重新序列化，**保留可识别的未知字段值，但可能改变格式、字段顺序、转义呈现**，会在保存预览中警告。
- **`.stringsdict`**：通过 Foundation `PropertyListSerialization` 读写；复数元数据与未知 plist 节点尽量保留，但**XML 将整体规范化**。新增复数条目遵循 `NSStringLocalizedFormatKey` 和 `NSStringPluralRuleType` 格式；生成新语言时保留规则元数据并清空翻译文本。
- **事务保存**：重新验证自扫描时的文件原始内容，再验证预览到保存期间的修改；在项目根目录 `.localization-workbench-backups/<timestamp>-<uuid>/` 保存每个原件和 `manifest.json`。复制/删除失败将尝试回滚已写文件，备份保留以供人工恢复。

### 备份恢复（可选）

每次保存会生成备份目录和包含原始相对路径的 `manifest.json`。恢复默认**只预览**，显式 `--apply` 才写盘：

```bash
python3 scripts/restore_backup.py /path/to/iOSProject list
python3 scripts/restore_backup.py /path/to/iOSProject <backup-folder-name>
python3 scripts/restore_backup.py /path/to/iOSProject <backup-folder-name> --apply
```

恢复前会再次备份当前文件，但恢复操作可能覆盖在该批保存之后的其他编辑；请确保 Git 已提交相关变更，并先查看 dry-run 输出。

## 3. macOS GUI 操作说明

- **⌘O** 打开工程；**⌘⇧O** 打开最近工程。
- **⌘S** 预览与保存；**⌘⇧S** 将当前翻译文本框的改动暂存。
- **⌘Z / ⌘⇧Z** 撤销/重做最近暂存的结构或值操作。直接文本输入仍可使用 macOS 文本框自身的编辑撤销。**暂存操作的撤销不会自动恢复未提交的输入文本**；如需完全清除，可使用 Discard。
- 左侧资源的完成率表示已发现条目中非空的语言值比例，**不是发布质量评分**。
- 翻译表格可水平滚动，点击 Key 打开右侧详细语言编辑，右键 Key 可复制、重命名或删除。
- **Key** 添加条目；对于 `.stringsdict`，需填写 plural variable 和数值类型（默认 count/d）。
- **Language** 为所选资源组添加语言；**Variant** 手动指定 `.xcstrings` 的 `variations/plural/one`、`variations/device/iphone` 或 `.stringsdict` 的 `count/one` 路径。
- **Diagnostics** 列出缺失/重复/复数/占位符问题；**Staged operations** 预览并调整尚未保存的更改。
- **Import/Export** 使用固定的 `group,key,variant,language,value` CSV 格式。导入时仅允许已存在的 group/key/variant，防止意外将不认识的列插入工程；新增 Key 需先在 GUI 建立。

## 4. CLI / Xcode CI

```bash
swift test
swift run localization-workbench scan Samples
swift run localization-workbench validate Samples
swift run localization-workbench validate Samples --strict
swift run localization-workbench export Samples --output /tmp/strings.csv
swift run localization-workbench import Samples --csv /tmp/strings.csv      # 安全预览，不写盘
swift run localization-workbench import Samples --csv /tmp/strings.csv --write
```

`validate` 默认有**错误**时退出 2；`--strict` 在任何警告时也退出 2，便于 CI 门禁。`import --write` 会保留备份并在文件冲突时拒绝覆盖。没有线上账号、自动翻译 API 或上传用户源码功能。

## 5. 文件结构

```text
LocalizationWorkbench_1.0/
├── Package.swift
├── LICENSE
├── README.md
├── BUILD_AND_TEST.md
├── Sources/
│   ├── LocalizationCore/
│   │   ├── Models.swift
│   │   ├── LegacyStrings.swift
│   │   ├── JSONText.swift
│   │   ├── WorkspaceLoader.swift
│   │   ├── WorkspaceWriter.swift              # 兼容旧版单值 API
│   │   ├── WorkspaceTransaction.swift         # 多文件事务/结构操作
│   │   └── ImportExport.swift
│   ├── LocalizationWorkbenchApp/
│   │   └── LocalizationWorkbenchApp.swift     # 原生 macOS GUI
│   └── LocalizationWorkbenchCLI/main.swift    # CI/终端工具
├── Tests/LocalizationCoreTests/
│   ├── LocalizationCoreTests.swift
│   └── WorkspaceTransactionTests.swift
├── Samples/
└── scripts/
    ├── build_app.sh
    ├── run_tests.sh
    └── restore_backup.py
```

## 6. 已知边界（不隐瞒）

1. **尚未完成 macOS 真机 GUI 编译/运行测试**；本环境为 Linux，无法签名/打开 SwiftUI App。`swiftc -frontend -parse` 不等价于 Apple SDK 类型检查。
2. 新创建的 `.lproj` 文件不会修改 `.pbxproj`。如果 Xcode 工程没有目录自动同步，需自行在 Xcode Project > Info > Localizations 中启用新语言，并确认 Target Membership；该工具不自动碰项目工程元数据。
3. `.xcstrings` 结构性更新和 `.stringsdict` 更新可能带来较大的 Git diff；请在 Review 画面仔细检查。
4. `.strings` 目前是 UTF-8 保守解析器；对于 UTF-16、罕见 OpenStep 转义和不能安全表示的 surrogate-pair 序列，**拒绝操作**，而不做潜在损坏的覆盖。
5. `.xcstrings` 的未来未知结构可通过 JSON 保留对象字段，但是当前仅对已识别的 `stringUnit`/变体提供 GUI 编辑，不保证所有 Apple 将来的 Catalog schema。
6. `.stringsdict` 新增复数 Key 预置 `other`；并不替代语言的 CLDR 规则选择和译文校对。
7. 本版本不提供云端实时协作、机器翻译、XLIFF、翻译记忆库、自动检测 UI 截断/文本布局、Xcode Target 精确关联或文件监听自动合并。
8. 保存使用同路径原子替换，可能改变文件系统的自定义权限/扩展属性；专业项目应配合 Git 管理并先在测试副本试运行。

## 7. 设计参考与许可证

- [Stringz](https://github.com/heysem-useinsider/Stringz) — 学习其资源侧边栏、进度提示、横向对照矩阵等**交互理念**；**没有复制源代码或 UI 资源**（Stringz 源码采用 GPL-3.0）。
- [iOSLocalizationEditor](https://github.com/igorkulman/iOSLocalizationEditor) — 学习轻量级 `.strings` 管理与缺失对照交互（MIT）。
- [Apple String Catalogs 文档](https://developer.apple.com/documentation/Xcode/localizing-and-varying-text-with-a-string-catalog) — 新式 Catalog 中的 plurals/device variants。
- [Apple `.stringsdict` 文档](https://developer.apple.com/documentation/xcode/localizing-strings-that-contain-plurals) — `other` 复数及必需的规则元数据。

Localization Workbench 的原创源代码以仓库内 `LICENSE`（MIT）发布。
