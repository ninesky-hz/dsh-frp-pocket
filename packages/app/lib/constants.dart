/// 全局常量：版本、契约版本、网关接口前缀。
///
/// 版本号与 `pubspec.yaml` 的 `version:` 保持一致，改版本时两处一起改。
library;

/// App 版本（与 pubspec version 的版本段一致）。
const String kAppVersion = '1.2.8';

/// App 构建号（与 pubspec version 的 `+N` 一致）。
const String kBuildNumber = '13';

/// 架构契约版本（见 docs/CONTRACT.md 标题 `v1`）。
const String kContractVersion = 'v1';

/// 网关 API 前缀（CONTRACT §4）。
const String kApiPrefix = '/frp-pocket/api';

/// 二维码 / 深链 scheme（CONTRACT §7.3）。
const String kDeepLinkScheme = 'dshfrp';

/// 主机探测超时（CONTRACT §7.2 要求 15s）。
const Duration kProbeTimeout = Duration(seconds: 15);

/// 示例主机域名（仅占位，不含任何真实地址）。
const String kExampleHomeUrl = 'https://home.dsh.example.com';
const String kExampleStudioUrl = 'https://studio.dsh.example.com';
