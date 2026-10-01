# Apple 签名与公证

公证用于从 GitHub 等渠道分发的 macOS 软件，是 Apple 自动安全检查，无需上架 App Store。当前本机仅有 Command Line Tools，已包含 `notarytool` 与 `stapler`；没有可用的开发者签名身份，因此当前 0.5.1 安装包仍是未公证的开发构建。

## 首次准备

1. 加入有效的 Apple Developer Program。会员注册、协议、付款与账号验证码由账号持有人完成。
2. 在 Apple 开发者账户申请 **Developer ID Application** 证书；导入本机钥匙串，并确保具有配套私钥。仅导入 `.cer` 而缺少对应私钥不能签名。MenuCraft 使用 DMG 分发，不需要用于 PKG 的 Developer ID Installer 证书。
3. 用 `security find-identity -v -p codesigning` 确认存在有效 Developer ID Application 身份。
4. 在自己的终端交互执行 `xcrun notarytool store-credentials MenuCraft-notary`。按提示提供 Apple ID、Team ID 与 App 专用密码，或使用受支持的 App Store Connect API 密钥。凭据保存在钥匙串，不写入项目或聊天。

证书和私钥留在钥匙串；不要将密码、`.p12`、`.p8` 或私钥提交到 GitHub。需要 GitHub 自动发布时，再将必要凭据配置到发布工作流的 Secrets。

## 构建与提交

在项目根目录执行，下列证书名称是占位示例，须替换为本机有效身份：

```sh
SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
  ARCHS=arm64 ./scripts/package.sh

./scripts/notarize.sh --check-only dist/MenuCraft-0.5.1-arm64.dmg

NOTARY_PROFILE=MenuCraft-notary \
  ./scripts/notarize.sh dist/MenuCraft-0.5.1-arm64.dmg
```

Intel 使用 `ARCHS=x86_64`；省略 `ARCHS` 构建 universal。DMG 文件名随应用版本变化。

正式签名分支为 7zz、设置程序、Finder 扩展和主程序启用 hardened runtime 与安全时间戳，并签名 DMG。公证脚本只读取、修改指定的构建安装包，不安装应用，不修改 `/Applications/MenuCraft.app`、用户配置或辅助功能权限。

脚本先检查实际 DMG 的签名和内部程序、签名团队、版本及调试权限。仅接受 Developer ID Application 签名，不接受 ad-hoc 构建。检查通过后，将 DMG 上传 Apple，等待 `Accepted`，下载日志，钉附公证票据、验证 Gatekeeper，再重新生成最终 SHA-256 校验文件。

签名预检通过不等于公证成功。没有真实证书、认证与 Apple 的 `Accepted` 结果时，不能声称已完成公证。

## 处理等待与失败

每次请求的 JSON 回执与 Apple 日志保存在被 Git 忽略的 `.build/notarization/`。默认等待 30 分钟，可通过 `NOTARY_TIMEOUT` 调整；超时后 Apple 仍可能继续处理，不要直接重复上传。用回执内的 ID 查询或继续等待：

```sh
xcrun notarytool info SUBMISSION_ID --keychain-profile MenuCraft-notary
xcrun notarytool wait SUBMISSION_ID --keychain-profile MenuCraft-notary
xcrun notarytool log SUBMISSION_ID --keychain-profile MenuCraft-notary apple-log.json
```

若后来返回 `Accepted`，对未改动的原 DMG 执行 `xcrun stapler staple`、`xcrun stapler validate` 与 Gatekeeper 检查，并重新生成校验文件。若返回 `Invalid`，查看日志后修复签名或打包问题并重新提交。

正式分发前仍应在干净环境验证下载安装、Finder 扩展、权限、滚动、归档与设置窗口生命周期；公证并不验证这些功能。首次从本地签名切换到 Developer ID 时，原辅助功能授权也可能需要用户按系统提示刷新。

## 官方资料

- [创建 Developer ID 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [准备签名与公证](https://developer.apple.com/developer-id/)
- [自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
