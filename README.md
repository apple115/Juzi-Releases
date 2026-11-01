# Juzi-Releases

Juzi 服务端二进制发布页，不含源码。

安装或升级：

```sh
curl -fsSL https://raw.githubusercontent.com/apple115/Juzi-Releases/master/install.sh | sh
```

入口走 `raw.githubusercontent.com`，资产通过 `api.github.com` 下载，不依赖 `github.com` 直连；可设置 `GITHUB_TOKEN` 提高 API 限额。

每个 release 包含 `juzi-server`、`juzi-remote`（Linux/macOS amd64/arm64）、`SHA256SUMS`、`release.json` 和 `install.sh`。安装脚本会校验摘要与协议，原子替换 `~/.local/bin` 下的二进制，并通过 `--handoff` 热替换正在运行的后台。
