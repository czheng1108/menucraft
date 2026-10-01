# 发布版本

版本号以根目录 VERSION 为准；BUILD_NUMBER 为整数构建号。构建脚本会同步写入主程序、设置程序和 Finder 扩展，不需要逐一修改生成的 Info.plist。

1. 更新 VERSION、BUILD_NUMBER 和 docs/RELEASE_NOTES.md。
2. 在 macOS 执行 ./scripts/test.sh，验证 Finder 菜单、滚动和操作窗口；需要权限的实际操作不能仅靠 CI 判断。
3. 提交变更并推送 main。
4. 在该提交创建与 VERSION 一致的标签（例如 v0.5.2）并推送标签。

Release 工作流从标签源码构建包含 arm64 与 x86_64 的单个 universal DMG，验证签名、生成校验文件后发布 GitHub Release。固定附件名保持 README 的最新版下载链接有效。workflow_dispatch 仅在选择一个有效版本标签时发布。

当前自动发布使用 ad-hoc 签名，不含 Apple 账号凭据。正式签名、公证准备见 NOTARIZATION.md；完成接入后同步更新安装说明和发布声明。

已发布标签应保持指向原提交；修复采用新版本，不覆盖既有版本包。
