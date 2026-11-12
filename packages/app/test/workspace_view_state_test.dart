import 'package:dsh_frp_app/models/workspace_view_state.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把 `workspace/follow` 的 `value` 包进完整的流帧信封里。
Map<String, Object?> _envelope(Map<String, Object?> value) {
  return <String, Object?>{'type': 'item', 'streamId': 'w1', 'value': value};
}

void main() {
  group('WorkspaceFrame.tryParse', () {
    test('baseline 的负载在 value.value 里', () {
      final frame = WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'baseline',
        'value': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'workspaceId': 'w1', 'title': 'A', 'path': '/a'},
          ],
          'archivedSessionIds': <Object?>['s9'],
          'pinnedSessionIds': <Object?>['s1'],
        },
      });

      expect(frame, isNotNull);
      expect(frame!.type, WorkspaceFrameType.baseline);
      expect(frame.workspaces.single.workspaceId, 'w1');
      expect(frame.workspaces.single.title, 'A');
      expect(frame.archivedSessionIds, <String>['s9']);
      expect(frame.pinnedSessionIds, <String>['s1']);
    });

    test('replace 是 baseline 的别名', () {
      final frame = WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'replace',
        'value': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'workspaceId': 'w1'},
          ],
        },
      });

      expect(frame?.type, WorkspaceFrameType.baseline);
      expect(frame?.workspaces.single.workspaceId, 'w1');
    });

    test('upsert / remove / order / archived / pinned 各自解析', () {
      final upsert = WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'upsert',
        'workspace': <String, Object?>{
          'workspaceId': 'w2',
          'title': '新工作区',
          'sessionIds': <Object?>['s3', 's4'],
        },
      });
      expect(upsert?.type, WorkspaceFrameType.upsert);
      expect(upsert?.workspace?.workspaceId, 'w2');
      expect(upsert?.workspace?.sessionIds, <String>['s3', 's4']);

      final remove = WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'remove',
        'workspaceId': 'w2',
      });
      expect(remove?.type, WorkspaceFrameType.remove);
      expect(remove?.workspaceId, 'w2');

      final order = WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'order',
        'workspaceIds': <Object?>['w2', 'w1'],
      });
      expect(order?.type, WorkspaceFrameType.order);
      expect(order?.workspaceIds, <String>['w2', 'w1']);

      final archived = WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'archived',
        'archivedSessionIds': <Object?>['s1', 's2'],
      });
      expect(archived?.type, WorkspaceFrameType.archived);
      expect(archived?.archivedSessionIds, <String>['s1', 's2']);

      final pinned = WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'pinned',
        'pinnedSessionIds': <Object?>['s3'],
      });
      expect(pinned?.type, WorkspaceFrameType.pinned);
      expect(pinned?.pinnedSessionIds, <String>['s3']);
    });

    test('形状不认识返回 null，不抛异常', () {
      expect(WorkspaceFrame.tryParse(<String, Object?>{'type': 'weird'}), isNull);
      expect(WorkspaceFrame.tryParse(<String, Object?>{}), isNull);
      expect(
        WorkspaceFrame.tryParse(<String, Object?>{
          'type': 'remove',
          'workspaceId': '',
        }),
        isNull,
      );
      expect(
        WorkspaceFrame.tryParse(<String, Object?>{'type': 'upsert'}),
        isNull,
      );
    });
  });

  test('decodeDshStreamFrame 把六种帧都带出 workspaceFrame', () {
    final baseline = decodeDshStreamFrame(
      _envelope(<String, Object?>{
        'type': 'baseline',
        'value': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'workspaceId': 'w1'},
          ],
        },
      }),
    );
    expect(baseline.kind, DshFrameKind.workspaceBaseline);
    expect(baseline.workspaceFrame?.type, WorkspaceFrameType.baseline);

    final payloads = <String, Map<String, Object?>>{
      'upsert': <String, Object?>{
        'workspace': <String, Object?>{'workspaceId': 'w9'},
      },
      'remove': <String, Object?>{'workspaceId': 'w9'},
      'order': <String, Object?>{
        'workspaceIds': <Object?>['w9'],
      },
      'archived': <String, Object?>{
        'archivedSessionIds': <Object?>['s9'],
      },
      'pinned': <String, Object?>{
        'pinnedSessionIds': <Object?>['s9'],
      },
    };
    for (final entry in <String, WorkspaceFrameType>{
      'upsert': WorkspaceFrameType.upsert,
      'remove': WorkspaceFrameType.remove,
      'order': WorkspaceFrameType.order,
      'archived': WorkspaceFrameType.archived,
      'pinned': WorkspaceFrameType.pinned,
    }.entries) {
      final payload = payloads[entry.key]!;
      final frame = decodeDshStreamFrame(
        _envelope(<String, Object?>{'type': entry.key, ...payload}),
      );
      expect(frame.kind, DshFrameKind.workspacePatch, reason: entry.key);
      expect(frame.workspaceFrame?.type, entry.value, reason: entry.key);
    }

    // 老式 patch 帧仍然归类，但没有可应用的增量（不该再触发整表重拉）。
    final legacy = decodeDshStreamFrame(
      _envelope(<String, Object?>{
        'type': 'patch',
        'patch': <Object?>[],
      }),
    );
    expect(legacy.kind, DshFrameKind.workspacePatch);
    expect(legacy.workspaceFrame, isNull);
  });

  test('baseline → upsert → remove → order → archived → pinned 逐帧收敛', () {
    final state = WorkspaceViewState();

    // 1) baseline：整份替换。
    expect(
      state.apply(
        WorkspaceFrame.tryParse(<String, Object?>{
          'type': 'baseline',
          'value': <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'workspaceId': 'w1',
                'title': '一号库',
                'path': '/repo/one',
                'sessionIds': <Object?>['s1', 's2'],
              },
              <String, Object?>{
                'workspaceId': 'w2',
                'title': '二号库',
                'path': '/repo/two',
                'sessionIds': <Object?>['s3'],
              },
            ],
            'archivedSessionIds': <Object?>['s9'],
            'pinnedSessionIds': <Object?>['s2'],
          },
        })!,
      ),
      isTrue,
    );
    expect(state.workspaces.map((item) => item.workspaceId), <String>['w1', 'w2']);
    expect(state.archivedSessionIds, <String>['s9']);
    expect(state.pinnedSessionIds, <String>['s2']);
    // 置顶 s2 提到最前，归档的 s9 根本不出现。
    expect(state.orderedSessionIds, <String>['s2', 's1', 's3']);

    // 2) upsert：按 workspaceId 追加。
    state.apply(
      WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'upsert',
        'workspace': <String, Object?>{
          'workspaceId': 'w3',
          'title': '三号库',
          'path': '/repo/three',
          'sessionIds': <Object?>['s4'],
        },
      })!,
    );
    expect(
      state.workspaces.map((item) => item.workspaceId),
      <String>['w1', 'w2', 'w3'],
    );
    expect(state.orderedSessionIds, <String>['s2', 's1', 's3', 's4']);

    // 3) upsert 已存在的 workspaceId：原地替换，不是追加。
    state.apply(
      WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'upsert',
        'workspace': <String, Object?>{
          'workspaceId': 'w1',
          'title': '一号库改名',
          'path': '/repo/one',
          'sessionIds': <Object?>['s1', 's2'],
        },
      })!,
    );
    expect(state.workspaces.length, 3);
    expect(state.workspaces.first.title, '一号库改名');
    expect(state.orderedSessionIds, <String>['s2', 's1', 's3', 's4']);

    // 4) remove：删掉工作区，它的会话跟着消失。
    state.apply(
      WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'remove',
        'workspaceId': 'w2',
      })!,
    );
    expect(
      state.workspaces.map((item) => item.workspaceId),
      <String>['w1', 'w3'],
    );
    expect(state.orderedSessionIds, <String>['s2', 's1', 's4']);

    // 5) order：只改顺序，成员不动。
    state.apply(
      WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'order',
        'workspaceIds': <Object?>['w3', 'w1'],
      })!,
    );
    expect(
      state.workspaces.map((item) => item.workspaceId),
      <String>['w3', 'w1'],
    );
    expect(state.orderedSessionIds, <String>['s2', 's4', 's1']);

    // 6) archived：全量替换归档集合。
    state.apply(
      WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'archived',
        'archivedSessionIds': <Object?>['s1'],
      })!,
    );
    expect(state.archivedSessionIds, <String>['s1']);
    expect(state.orderedSessionIds, <String>['s2', 's4']);
    expect(state.isArchived('s1'), isTrue);

    // 7) pinned：全量替换置顶集合。
    state.apply(
      WorkspaceFrame.tryParse(<String, Object?>{
        'type': 'pinned',
        'pinnedSessionIds': <Object?>['s4'],
      })!,
    );
    expect(state.pinnedSessionIds, <String>['s4']);
    expect(state.orderedSessionIds, <String>['s4', 's2']);
    expect(state.isPinned('s4'), isTrue);
  });

  test('没有真正变化的帧返回 false，调用方据此跳过 setState', () {
    final state = WorkspaceViewState()
      ..apply(
        WorkspaceFrame.tryParse(<String, Object?>{
          'type': 'baseline',
          'value': <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'workspaceId': 'w1',
                'title': '一号库',
                'path': '/repo/one',
                'sessionIds': <Object?>['s1'],
              },
            ],
            'pinnedSessionIds': <Object?>['s1'],
          },
        })!,
      );

    // 同样的 pinned 再来一遍：状态没变。
    expect(
      state.apply(
        WorkspaceFrame.tryParse(<String, Object?>{
          'type': 'pinned',
          'pinnedSessionIds': <Object?>['s1'],
        })!,
      ),
      isFalse,
    );
    // 删一个不存在的工作区：状态没变。
    expect(
      state.apply(
        WorkspaceFrame.tryParse(<String, Object?>{
          'type': 'remove',
          'workspaceId': 'nope',
        })!,
      ),
      isFalse,
    );
    // 空 order：状态没变。
    expect(
      state.apply(
        WorkspaceFrame.tryParse(<String, Object?>{
          'type': 'order',
          'workspaceIds': <Object?>[],
        })!,
      ),
      isFalse,
    );
  });

  test('mentions / workspaceOf 能定位归档与未归档的会话', () {
    final state = WorkspaceViewState()
      ..apply(
        WorkspaceFrame.tryParse(<String, Object?>{
          'type': 'baseline',
          'value': <String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'workspaceId': 'w1',
                'title': '一号库',
                'path': '/repo/one',
                'sessionIds': <Object?>['s1', 's2'],
              },
            ],
            'archivedSessionIds': <Object?>['s2'],
          },
        })!,
      );

    expect(state.mentions('s1'), isTrue);
    expect(state.mentions('s2'), isTrue, reason: '归档的会话也算提过');
    expect(state.mentions('s3'), isFalse);
    expect(state.workspaceOf('s1')?.workspaceId, 'w1');
    expect(state.workspaceOf('s2'), isNotNull);
    expect(state.workspaceOf('s3'), isNull);
  });
}
