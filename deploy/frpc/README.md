# PC 侧（家里 / 工作室）frpc 说明

## 两台 PC 的差异只有三处

| 项 | 家里 | 工作室 |
| --- | --- | --- |
| `subdomain` | `home` | `studio` |
| 公网地址 | `https://home.dsh.example.com` | `https://studio.dsh.example.com` |
| `[[proxies]].name` | `dsh-frp-home` | `dsh-frp-studio` |
| PIN | **各自独立**（插件首次启动随机生成） | 同上 |
| `displayName` | 家里 | 工作室 |

两台都可以用 `localPort = 3081`：网关只绑各自的 `127.0.0.1`，互不冲突。
**同一个 `subdomain` 不要在两台机器上同时用**——frps 后注册的会把先注册的踢掉，表现为另一台突然 404。

## 什么时候用哪个文件

| 场景 | 用什么 |
| --- | --- |
| 正常使用 | 什么都不用管。插件在设置页里管 frpc 生命周期，自动生成 `$DSH_HOME\dsh-frp-pocket\frpc.toml` |
| 排查「是 frp 的问题还是插件的问题」 | 用本目录的 `frpc-home.toml` 手工起一个 frpc（先把 `VPS_IP`/`FRP_TOKEN` 换成真值） |
| 插件报 `frpc_not_found` | 跑 `install-pc.ps1`，把 frpc.exe 落到 `%LOCALAPPDATA%\dsh-frp-pocket\frp\` |
| 想让 frpc 开机自启、不依赖插件 | `install-pc.ps1 -Mode ScheduledTask` |

手工验证（不启动插件，只看 frp 通不通）：

```powershell
# 1) 复制模板并替换占位符
copy deploy\frpc\frpc-home.toml "$env:LOCALAPPDATA\dsh-frp-pocket\frpc-manual.toml"
notepad "$env:LOCALAPPDATA\dsh-frp-pocket\frpc-manual.toml"   # 改 VPS_IP / FRP_TOKEN

# 2) 校验配置
frpc verify -c "$env:LOCALAPPDATA\dsh-frp-pocket\frpc-manual.toml"

# 3) 前台跑（能直接看到日志，Ctrl+C 结束）
frpc -c "$env:LOCALAPPDATA\dsh-frp-pocket\frpc-manual.toml"
```

看到这两行就说明 frp 通了：

```
login to server success, get run id [...]
[start proxy success]
```

此时如果公网访问是 **502**，说明 frp 没问题、是网关（3081）没起——去开插件。

## 三种代理写法的取舍

| 写法 | 配置 | 前提 | 适用 |
| --- | --- | --- | --- |
| `subdomain = "home"` | 最短 | frps 配了 `subDomainHost` | 默认，推荐 |
| `customDomains = ["home.dsh.example.com"]` | 显式全名 | 域名 DNS 指到 VPS | 域名不在 `subDomainHost` 下、或多域名 |
| `remotePort = 30001` | 走端口 | frps `allowPorts` 放行 | 没有域名/证书时临时用；**无 TLS**，不建议长期 |

## 防火墙与网络

- **不需要**在 Windows 防火墙上开 3081：frpc 是主动出站连 VPS 的 7000，网关只在回环上。
- 需要能出站访问 `VPS_IP:7000/tcp`。公司网络禁自定义端口时，把 frps 的 `bindPort` 改成 443 也可（但 443 已被 Caddy 占，需另想办法，见 `docs/TROUBLESHOOT.md`）。
- 睡眠会断隧道：`powercfg /change standby-timeout-ac 0`，或在「电源和电池」里把睡眠设为「从不」。
