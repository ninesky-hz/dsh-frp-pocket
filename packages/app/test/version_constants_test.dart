import 'dart:io';

import 'package:dsh_frp_app/constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// constants.dart 里的 kAppVersion / kBuildNumber 是手写的，
/// 出包时只改 pubspec 忘了改这里，设置页就会一直报旧版本（曾经停在 1.3.4+19）。
/// 这条测试把两处钉在一起，改漏了直接红。
void main() {
  test('kAppVersion / kBuildNumber 与 pubspec.yaml 的 version 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final line = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    expect(line, isNotNull, reason: 'pubspec.yaml 里找不到 version:');

    final parts = line!.split('+');
    expect(
      kAppVersion,
      parts.first,
      reason: '改了 pubspec 的版本段，constants.dart 的 kAppVersion 也要一起改',
    );
    if (parts.length > 1) {
      expect(
        kBuildNumber,
        parts[1],
        reason: '改了 pubspec 的 +N，constants.dart 的 kBuildNumber 也要一起改',
      );
    }
  });
}
