import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models.dart';

/// 信令连接服务：负责 WebSocket 连接、房间管理、位置消息分发，
/// 并把通话信令原样转发给 CallService。
class SocketService extends ChangeNotifier {
  static final SocketService instance = SocketService._();

  SocketService._();

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _backoff = 0;
  bool _manualClose = false;
  bool _everJoined = false;

  String serverUrl = '';
  String myName = '';
  String? myId;
  String? roomCode;
  bool joined = false;
  String? lastError;

  /// 房间全部成员（含自己），key 为成员 id
  final Map<String, MemberState> members = {};

  /// 通话信令回调（由 CallService 注册）
  void Function(Map<String, dynamic> msg)? onCallSignal;
  VoidCallback? onMemberLeft;

  bool get isConnected => _channel != null && joined;

  /// 连接服务器并加入房间
  Future<void> connectAndJoin({
    required String serverUrl,
    required String roomCode,
    required String name,
  }) async {
    this.serverUrl = serverUrl.trim();
    this.roomCode = roomCode.trim().toUpperCase();
    myName = name.trim().isEmpty ? '我' : name.trim();
    _manualClose = false;
    _everJoined = false;
    _backoff = 0;
    await _connect();
  }

  Future<void> _connect() async {
    _pingTimer?.cancel();
    joined = false;
    lastError = null;
    notifyListeners();
    var url = serverUrl.trim();
    if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      url = 'ws://$url';
    }
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      channel.stream.listen(
        _onData,
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
        cancelOnError: true,
      );
      _sendRaw({
        'type': 'join',
        'room': roomCode,
        'name': myName,
      });
    } catch (e) {
      lastError = '无法连接服务器：$e';
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'joined':
        _everJoined = true;
        _backoff = 0;
        joined = true;
        final newId = msg['id'] as String;
        // 重连后 id 变化，清理旧成员映射里的自己
        members.remove(myId);
        myId = newId;
        members[newId] = MemberState(id: newId, name: myName);
        for (final m in (msg['members'] as List? ?? [])) {
          final mm = MemberState.fromJson(m as Map<String, dynamic>);
          members[mm.id] = mm;
        }
        break;
      case 'member-joined':
        members[msg['id'] as String] =
            MemberState.fromJson(msg);
        break;
      case 'member-left':
        members.remove(msg['id'] as String);
        onMemberLeft?.call();
        break;
      case 'loc':
        final m = members[msg['id'] as String];
        if (m != null) {
          m.lat = (msg['lat'] as num?)?.toDouble();
          m.lng = (msg['lng'] as num?)?.toDouble();
          m.heading = (msg['heading'] as num?)?.toDouble();
          m.accuracy = (msg['accuracy'] as num?)?.toDouble();
          m.ts = msg['ts'] as int?;
        }
        break;
      case 'ping':
        _sendRaw({'type': 'pong'});
        return; // 不需要 notify
      default:
        if ((msg['type'] as String?)?.startsWith('call') == true) {
          onCallSignal?.call(msg);
        }
        return;
    }
    notifyListeners();
  }

  void _onDisconnect() {
    _pingTimer?.cancel();
    _channel = null;
    if (_manualClose) {
      joined = false;
      notifyListeners();
      return;
    }
    joined = false;
    lastError = _everJoined ? '连接断开，正在重连…' : lastError ?? '连接失败，正在重连…';
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _backoff = _backoff == 0 ? 1 : min(_backoff * 2, 30);
    _reconnectTimer = Timer(Duration(seconds: _backoff), _connect);
  }

  /// 手动立即重连
  Future<void> reconnectNow() async {
    _reconnectTimer?.cancel();
    _backoff = 0;
    _channel?.sink.close();
    _channel = null;
    await _connect();
  }

  void _sendRaw(Map<String, dynamic> msg) {
    try {
      _channel?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  void sendLocation({
    required double lat,
    required double lng,
    double? heading,
    double? accuracy,
  }) {
    _sendRaw({
      'type': 'loc',
      'lat': lat,
      'lng': lng,
      'heading': heading,
      'accuracy': accuracy,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void leaveRoom() {
    _manualClose = true;
    _sendRaw({'type': 'leave'});
    members.clear();
    joined = false;
    myId = null;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    notifyListeners();
  }

  // ---- 通话信令（转发给服务器，CallService 调用） ----
  void callInvite() => _sendRaw({'type': 'call-invite'});
  void callAccept() => _sendRaw({'type': 'call-accept'});
  void callOffer(String to, String sdp) =>
      _sendRaw({'type': 'call-offer', 'to': to, 'sdp': sdp});
  void callAnswer(String to, String sdp) =>
      _sendRaw({'type': 'call-answer', 'to': to, 'sdp': sdp});
  void callIce(String to, Map<String, dynamic> candidate) =>
      _sendRaw({'type': 'call-ice', 'to': to, 'candidate': candidate});
  void callEnd() => _sendRaw({'type': 'call-end'});
}
