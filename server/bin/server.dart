import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 位置共享 App 信令服务器
/// 功能：
///  1. 房间管理（创建/加入/退出，支持两人与多人）
///  2. 位置数据中继（成员间转发 GPS 坐标）
///  3. WebRTC 通话信令中继（invite/accept/offer/answer/ice/end）

final Map<String, Room> _rooms = {};
final List<WebSocketChannel> _monitors = [];

class Member {
  final String id;
  final String name;
  final WebSocketChannel socket;
  final int joinedAt = DateTime.now().millisecondsSinceEpoch;
  String? roomCode;
  double? lat, lng, heading, accuracy;
  int? lastTs;
  Timer? pingTimer;
  Member(this.id, this.name, this.socket);
}

class Room {
  final String code;
  final Map<String, Member> members = {};
  final Set<String> inCall = {}; // 正在通话中的成员 id
  Room(this.code);
}

void main(List<String> args) {
  final port = int.tryParse(
          args.isNotEmpty ? args[0] : Platform.environment['PORT'] ?? '') ??
      8888;
  final server = HttpServer.bind(InternetAddress.anyIPv4, port);
  print('位置共享信令服务器已启动: ws://0.0.0.0:$port');
  server.then((s) {
    s.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        WebSocketTransformer.upgrade(req).then((ws) {
          _handleSocket(IOWebSocketChannel(ws));
        });
      } else {
        await _serveHttp(req);
      }
    });
  });
}

/// HTTP：/monitor 输出监视终端页面，其余输出健康检查文本
Future<void> _serveHttp(HttpRequest req) async {
  final path = req.uri.path;
  if (path == '/monitor' || path == '/monitor.html') {
    final file = File('public/monitor.html');
    if (await file.exists()) {
      req.response.headers.contentType = ContentType.html;
      await req.response.addStream(file.openRead());
      await req.response.close();
      return;
    }
  }
  req.response.headers.contentType = ContentType.text;
  req.response.write('LocationShare Signaling Server. OK.');
  await req.response.close();
}

void _handleSocket(WebSocketChannel ws) {
  Member? member;
  bool isMonitor = false;
  ws.stream.listen(
    (data) {
      if (data is! String) return;
      try {
        final msg = jsonDecode(data) as Map<String, dynamic>;
        if (isMonitor) {
          _onMonitorMessage(msg, ws);
          return;
        }
        final first = member == null;
        member = _onMessage(member, msg, ws);
        // 首条消息若申请监视员身份，则切换为监视会话
        if (first && msg['type'] == 'monitor' && member == null) {
          isMonitor = true;
        }
      } catch (e) {
        print('消息解析失败: $e');
      }
    },
    onDone: () {
      if (isMonitor) {
        _monitors.remove(ws);
        print('监视终端断开 (在线${_monitors.length})');
      } else if (member != null) {
        _removeMember(member!);
      }
    },
    onError: (_) {
      if (isMonitor) {
        _monitors.remove(ws);
      } else if (member != null) {
        _removeMember(member!);
      }
    },
    cancelOnError: true,
  );
}

/// 监视终端：接入快照 + 实时事件 + 控制指令
void _onMonitorMessage(Map<String, dynamic> msg, WebSocketChannel ws) {
  if (!_monitors.contains(ws)) return; // 密钥错误被拒的会话不响应指令
  switch (msg['type']) {
    case 'monitor-snapshot':
      _send(ws, _snapshot());
      break;
    case 'monitor-kick':
      final room = _rooms[_normalizeRoom(msg['room'] as String?)];
      final target = room?.members[msg['id']];
      if (target != null) {
        _send(target.socket, {'type': 'notice', 'text': '你已被管理员移出房间'});
        target.socket.sink.close();
        _log('监视终端将 ${target.name} 移出房间 ${room!.code}');
      }
      break;
    case 'monitor-broadcast':
      final room = _rooms[_normalizeRoom(msg['room'] as String?)];
      final text = (msg['text'] as String?) ?? '';
      if (room != null && text.isNotEmpty) {
        _broadcast(room, {'type': 'notice', 'text': text});
        _log('监视终端向房间 ${room.code} 发送公告: $text');
      }
      break;
  }
}

Map<String, dynamic> _snapshot() {
  return {
    'type': 'monitor-snapshot',
    'ts': DateTime.now().millisecondsSinceEpoch,
    'rooms': _rooms.values.map((r) {
      return {
        'code': r.code,
        'inCall': r.inCall.toList(),
        'members': r.members.values.map((m) => {
              'id': m.id,
              'name': m.name,
              'lat': m.lat,
              'lng': m.lng,
              'heading': m.heading,
              'accuracy': m.accuracy,
              'ts': m.lastTs,
              'inCall': r.inCall.contains(m.id),
              'joinedAt': m.joinedAt,
            }).toList(),
      };
    }).toList(),
  };
}

void _notifyMonitors(Map<String, dynamic> msg) {
  for (final ws in List.of(_monitors)) {
    _send(ws, msg);
  }
}

void _log(String text) {
  print(text);
  _notifyMonitors({'type': 'monitor-log', 'text': text,
      'ts': DateTime.now().millisecondsSinceEpoch});
}

Member? _onMessage(Member? member, Map<String, dynamic> msg, WebSocketChannel ws) {
  final type = msg['type'] as String?;

  // 监视终端接入（首条消息）
  if (type == 'monitor') {
    final key = Platform.environment['MONITOR_KEY'];
    final provided = msg['key'] as String?;
    if (key == null || key.isEmpty || key == provided) {
      _monitors.add(ws);
      _send(ws, _snapshot());
      _log('监视终端已接入 (在线${_monitors.length})');
    } else {
      _send(ws, {'type': 'monitor-denied'});
    }
    return null; // 非成员会话
  }

  // 加入房间是第一条消息
  if (type == 'join') {
    final name = (msg['name'] as String?) ?? '成员';
    final roomCode = _normalizeRoom(msg['room'] as String?);
    final id = 'm${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '${_rand(4)}';
    member = Member(id, name, ws);

    final room = _rooms.putIfAbsent(roomCode, () => Room(roomCode));
    member.roomCode = roomCode;
    room.members[id] = member;

    _send(ws, {
      'type': 'joined',
      'id': id,
      'room': roomCode,
      'members': room.members.values
          .map((m) => {'id': m.id, 'name': m.name})
          .toList(),
    });
    // 通知房间内其他人
    _broadcast(room, {
      'type': 'member-joined',
      'id': id,
      'name': name,
    }, exclude: id);
    _log('[$roomCode] $name 加入 (id=$id, 当前${room.members.length}人)');
    _notifyMonitors({
      'type': 'monitor-event', 'event': 'join', 'room': roomCode,
      'id': id, 'name': name, 'count': room.members.length,
    });

    // 心跳保活
    member.pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _send(ws, {'type': 'ping'});
    });
    return member;
  }

  if (member == null) return null;
  final m = member;
  final room = _rooms[m.roomCode];
  if (room == null) return m;

  switch (type) {
    case 'loc': // 位置更新 → 广播给房间其他人 + 记录给监视终端
      m.lat = (msg['lat'] as num?)?.toDouble();
      m.lng = (msg['lng'] as num?)?.toDouble();
      m.heading = (msg['heading'] as num?)?.toDouble();
      m.accuracy = (msg['accuracy'] as num?)?.toDouble();
      m.lastTs = msg['ts'] as int?;
      _broadcast(room, {
        'type': 'loc',
        'id': m.id,
        'lat': m.lat,
        'lng': m.lng,
        'heading': m.heading,
        'accuracy': m.accuracy,
        'ts': m.lastTs,
      }, exclude: m.id);
      _notifyMonitors({
        'type': 'monitor-loc', 'room': room.code, 'id': m.id,
        'lat': m.lat, 'lng': m.lng, 'heading': m.heading,
        'accuracy': m.accuracy, 'ts': m.lastTs,
      });
      break;

    case 'call-invite': // 发起通话 → 通知房间所有人
      room.inCall.add(m.id);
      _notifyMonitors({
        'type': 'monitor-event', 'event': 'call-start', 'room': room.code,
        'id': m.id, 'name': m.name,
      });
      _broadcast(room, {'type': 'call-incoming', 'from': m.id, 'name': m.name},
          exclude: m.id);
      break;

    case 'call-accept': // 接受通话 → 通知所有人（已接受者会向其发 offer）
      room.inCall.add(m.id);
      _broadcast(room, {'type': 'call-accepted', 'from': m.id}, exclude: m.id);
      break;

    case 'call-offer': // SDP Offer 点对点转发
      _forward(room, msg['to'] as String?, {
        'type': 'call-offer',
        'from': m.id,
        'sdp': msg['sdp'],
      });
      break;

    case 'call-answer': // SDP Answer 点对点转发
      _forward(room, msg['to'] as String?, {
        'type': 'call-answer',
        'from': m.id,
        'sdp': msg['sdp'],
      });
      break;

    case 'call-ice': // ICE 候选点对点转发
      _forward(room, msg['to'] as String?, {
        'type': 'call-ice',
        'from': m.id,
        'candidate': msg['candidate'],
      });
      break;

    case 'call-end': // 挂断 → 通知所有人
      room.inCall.remove(m.id);
      _broadcast(room, {'type': 'call-ended', 'from': m.id}, exclude: m.id);
      break;

    case 'pong':
      break; // 心跳应答，无需处理
  }
  return m;
}

void _removeMember(Member m) {
  m.pingTimer?.cancel();
  final room = _rooms[m.roomCode];
  if (room != null) {
    room.members.remove(m.id);
    room.inCall.remove(m.id);
    _broadcast(room, {'type': 'member-left', 'id': m.id}, exclude: m.id);
    _notifyMonitors({
      'type': 'monitor-event', 'event': 'leave', 'room': room.code,
      'id': m.id, 'name': m.name, 'count': room.members.length,
    });
    if (room.members.isEmpty) {
      _rooms.remove(room.code);
      _log('[${room.code}] 房间已解散');
      _notifyMonitors({'type': 'monitor-event', 'event': 'room-closed',
          'room': room.code});
    }
  }
  _log('${m.name} 断开连接');
}

void _send(WebSocketChannel ws, Map<String, dynamic> msg) {
  try {
    ws.sink.add(jsonEncode(msg));
  } catch (_) {}
}

void _broadcast(Room room, Map<String, dynamic> msg, {String? exclude}) {
  for (final m in room.members.values) {
    if (m.id != exclude) _send(m.socket, msg);
  }
}

void _forward(Room room, String? to, Map<String, dynamic> msg) {
  final target = room.members[to];
  if (target != null) _send(target.socket, msg);
}

String _normalizeRoom(String? raw) {
  var code = (raw ?? '').trim().toUpperCase();
  code = code.replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (code.length < 4) code = code.padRight(4, '0');
  return code.length > 8 ? code.substring(0, 8) : code;
}

String _rand(int len) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random();
  return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
}
