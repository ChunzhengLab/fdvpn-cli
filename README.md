# fdvpn-cli

适用于 macOS zsh 环境的复旦 VPN 管理函数，基于 OpenConnect 启动、停止和查看 VPN 状态，并从 macOS Keychain 读取 VPN 凭据。

## 依赖
```zsh
brew install openconnect expect
```

## 使用
```zsh
fdvpn start    # 启动 VPN
fdvpn status   # 查看状态
fdvpn stop     # 停止 VPN
fdvpn          # 查看状态
```

## 配置
将 VPN 用户名和密码写入 Keychain：
```zsh
security add-generic-password -s "fdvpn" -a "user" -w "您的 VPN 用户名" -U
security add-generic-password -s "fdvpn" -a "pass" -w "您的 VPN 密码" -U
```
将 fdvpn 函数加入 ~/.zshrc，然后重新加载：
```zsh
source ~/.zshrc
```
