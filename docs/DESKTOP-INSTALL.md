# 装进 Desktop 版 DSH（Electron 托管 profile）

Desktop 版的 `desktop` profile 由 Electron 应用独占，CLI 会直接拒绝：

```bash
$ node "D:/DeepSeek Harness/resources/app/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" \
    plugin --profile desktop add -w "D:/Ai-Project/dsh-frp-pocket/packages/plugin"
error: profile "desktop" is managed exclusively by the Electron application
```

所以走等价的三步手工安装（和 `link:` 依赖完全一样，`dsh-session-vault` 就是这么装的）。

## 1. 加依赖 + 注册 bundle

编辑 `%USERPROFILE%\.dsh\profiles\desktop\package.json`，两处都要改：

```json
{
  "dependencies": {
    "dsh-frp-pocket": "link:D:/Ai-Project/dsh-frp-pocket/packages/plugin"
  },
  "dsh": {
    "profile": {
      "bundles": ["...", "dsh-frp-pocket", "..."]
    }
  }
}
```

只加 `dependencies` 不够——`bundles` 决定启动时加载谁。

## 2. 装进 profile 的 node_modules

```bash
cd "$USERPROFILE/.dsh/profiles/desktop"
pnpm install --prefer-offline --ignore-scripts
ls -l node_modules/dsh-frp-pocket   # 应为符号链接 → 仓库目录
```

## 3. 完全退出并重开 DSH Desktop

插件在启动时加载，**不热更新**。重开后：

```bash
netstat -ano | grep ":3081" | grep LISTENING     # 网关在听
curl -s https://home.dsh.chenz.vip/frp-pocket/api/info   # 200，hostId 与本地一致
```

## 预置配置（可选）

CLI 用 `DSH_HOME` 指向桌面 profile 用的同一个主目录，就能在插件加载前把配置写好：

```bash
cd D:/Ai-Project/dsh-frp-pocket
export DSH_HOME="C:/Users/<你>/.dsh"
node packages/plugin/bin/dsh-frp-pocket.mjs config set frp.serverAddr "$VPS_IP"
node packages/plugin/bin/dsh-frp-pocket.mjs config set frp.authToken "$FRP_TOKEN"
node packages/plugin/bin/dsh-frp-pocket.mjs config set frp.mode customDomains
node packages/plugin/bin/dsh-frp-pocket.mjs config set frp.customDomains home.dsh.chenz.vip
node packages/plugin/bin/dsh-frp-pocket.mjs config set frp.publicUrl https://home.dsh.chenz.vip
```

写完后 `config get` 里 `authToken` 显示为空、`authTokenSet: true` 是**正常的**——读取时脱敏，落盘仍是明文（和 `frpc.toml` 同级风险，文件权限取决于用户目录）。

## 回滚

```bash
cd "$USERPROFILE/.dsh/profiles/desktop"
cp package.json.bak-frp-* package.json
pnpm install --prefer-offline
```

`package.json` 和 `pnpm-lock.yaml` 在改动前都备份成了 `*.bak-frp-<时间戳>`。

## 已知边界

- `pnpm install` 会把 profile 的依赖重新落一遍（本次 277 个包，全部命中本地 store，52 秒，无下载）。运行中的应用已加载的模块不受影响，但**别在长任务中途做**。
- 桌面应用自己也可能改写 `package.json`（它会在插件市场操作时重排），改动后建议顺手确认 `bundles` 里还有 `dsh-frp-pocket`。
