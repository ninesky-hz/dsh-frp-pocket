---
revision: 1
updated: 2026-11-12T05:49:31.129Z
objective_sha256: d4621792fe68
---

# 目标

## 目标陈述

让 dsh-frp-pocket 满足 YG 的三项现场需求并全部实测验证：(1) 插件面板的公网地址可自定义（含任意 HTTPS URL）；(2) frps 不再显示裸 IP，改用域名 dsh.chenz.vip 且隧道仍通；(3) 修掉「手机 App 扫码保存后列表里没有该主机」的 bug，并重出可安装 APK。

## 约束

- 不改动 VPS 上既有业务站点与 frps.toml（当前是共用 frps）
- 插件改动必须 node --test 全绿；App 改动必须 flutter analyze 0 问题、flutter test 全绿
- 真实值（token/PIN/域名）只存本机配置与 .agi，不写进源码与文档
- 不新增 npm/pub 依赖

## 里程碑

- [x] 定位 App 保存丢失根因并复现（widget test 先红：`AppScope 未挂载到 widget 树`，`host_edit_screen.dart:130`）
- [x] 插件面板支持内联自定义公网地址 + frps 支持域名（`client/index.js` saveAddress；设置页 hint；`lib/index.js` liveConfig 对账）
- [x] App 修复后 widget test 转绿，analyze 0 问题 / test 44 通过
- [x] 本机实测：serverAddr=dsh.chenz.vip 时 frpc running 且 https 公网可达（13:57:10 login success + start proxy success；health 401 = 网关在响应）
- [x] 重建 arm64 release APK：`packages/app/build/app/outputs/flutter-apk/app-release.apk`（36141046 字节）

## 范围之外

- 重装/改造 VPS 的 Caddy 与 frps 服务
- 新增工作室主机
- iOS 端
- 把 PIN 或 token 提交进 git

## 自主回合上限

12
