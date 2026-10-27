# WindLabMac 开发说明

WindLab 的 SwiftPM macOS 应用工程。已实现模块、当前进展、截图及未实现功能统一维护在[项目主 README](../../README.md)，避免两份功能清单互相矛盾。

## 环境

- macOS 14 或以上。
- 支持 Swift 6.1 的 Xcode / Command Line Tools。
- `WindogCore` 使用系统 zlib；测试中的独立 ZIP 校验使用 macOS 自带 `unzip`，XML 校验使用 Foundation。
- 应用、构建和测试不依赖 Python。研究目录的辅助脚本不属于应用依赖。

## 构建、测试与启动

以下命令在当前目录执行：

```bash
swift build
swift test
./scripts/package_app.sh
open ./dist/WindLab.app
```

`package_app.sh` 默认构建 Release；调试应用包使用：

```bash
WINDLAB_BUILD_CONFIGURATION=debug ./scripts/package_app.sh
```

受限环境中若 SwiftPM 嵌套沙箱不可用：

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache" \
swift test --disable-sandbox

WINDLAB_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/package_app.sh
```

产物位于 `dist/WindLab.app`。建议通过 `.app` 启动图形界面；不要把裸命令行可执行文件的启动行为当作应用包验收。脚本使用本地 ad-hoc 签名，并检查签名、Python 文件/运行库和旧解析器启动路径。当前没有公证发行流程。

## 工程组成

| 目录 | 职责 |
|---|---|
| `Sources/WindogCore` | `.windog` 编解码、文本导入、统计计算和数据导出 |
| `Sources/WindLabMac` | 界面、配置草稿、原生分析适配与文件打开协调 |
| `Sources/CZlib` | 系统 zlib 的模块声明 |
| `Tests/WindogCoreTests` | 核心算法、文件格式、独立 CSV/ZIP/XML 校验 |
| `Tests/WindLabMacTests` | 配置、页面数据、图形生成与实际文件集成检查 |
| `scripts` / `assets` | 应用打包、签名检查及图标 |

## 验证记录

最近一次完整回归：**2026-10-27，116 项通过，0 失败**，使用 `swift test --disable-sandbox` 在提交前重新执行。

部分集成测试读取本地 `test-data` 或工作区已有测风文件；这些数据不随仓库分发，缺失时部分测试会跳过。测试完成不等于已对所有 `.windog` 结构作兼容保证。

## 开发时需要保留的边界

- 保存既有 `.windog` 目前只支持列标签、单位修改，其余未恢复字节保持原样；不得把未知元数据按猜测位置写回。
- 配置、图表及统计应从同一 Swift 数据模型生成，不能用四舍五入后的界面值重新计算。
- 配置月统计图箱边是平均每日极值，不是四分位数；配置 PDF 默认15～40箱。
- Histogram 月/小时图采用组内频率，表格采用全局联合频率；两种口径应明确标注。
- Histogram/Rose 的 Include 标记筛选已可用，其他页面和导出尚未统一；不能将其描述为全局筛选已实现。
- 复杂公式、专有模板、完整配置持久化及未实现模块的边界见[主 README](../../README.md)。
