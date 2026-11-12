/// 全局常量：版本、契约版本、网关接口前缀。
///
/// 版本号与 `pubspec.yaml` 的 `version:` 保持一致，改版本时两处一起改。
library;

/// App 版本（与 pubspec version 的版本段一致）。
const String kAppVersion = '1.1.0';

/// App 构建号（与 pubspec version 的 `+N` 一致）。
const String kBuildNumber = '2';

/// 架构契约版本（见 docs/CONTRACT.md 标题 `v1`）。
const String kContractVersion = 'v1';

/// 网关 API 前缀（CONTRACT §4）。
const String kApiPrefix = '/frp-pocket/api';

/// 二维码 / 深链 scheme（CONTRACT §7.3）。
const String kDeepLinkScheme = 'dshfrp';

/// 主机探测超时（CONTRACT §7.2 要求 15s）。
const Duration kProbeTimeout = Duration(seconds: 15);

/// 桌面 UA，用于排查 dsh web 的桌面/移动布局差异。
const String kDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 示例主机域名（仅占位，不含任何真实地址）。
const String kExampleHomeUrl = 'https://home.dsh.example.com';
const String kExampleStudioUrl = 'https://studio.dsh.example.com';
