import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/io.dart';

/// 冒烟测试：监视终端协议验证
Future<void> main() async {
  final results = <String, bool>{};

  // 1. 监视终端连接
  final mon = IOWebSocketChannel.connect('ws://localhost:8888');
  final monMsgs = <Map<String, dynamic>>[];
  mon.stream.listen((d) => monMsgs.add(jsonDecode(d as String)));
  mon.sink.add(jsonEncode({'type': 'monitor'}));

  // 2. 假成员加入 + 发位置 + 发起通话
  await Future.delayed(const Duration(milliseconds: 500));
  final mem = IOWebSocketChannel.connect('ws://localhost:8888');
  final joined = Completer<void>();
  final kicked = Completer<void>();
  String memId = '';
  mem.stream.listen((d) {
    final m = jsonDecode(d as String);
    if (m['type'] == 'joined' && !joined.isCompleted) {
      memId = m['id'] as String;
      joined.complete();
    } else if (m['type'] == 'notice') {
      print('  (成员收到公告: ${m['text']})');
    }
  }, onDone: () {
    if (!kicked.isCompleted) kicked.complete();
  });
  mem.sink.add(jsonEncode({'type': 'join', 'name': '测试员', 'room': 'abcd'}));
  await joined.future;
  mem.sink.add(jsonEncode({
    'type': 'loc', 'lat': 39.9042, 'lng': 116.4074,
    'heading': 45.0, 'accuracy': 12.5, 'ts': DateTime.now().millisecondsSinceEpoch,
  }));
  mem.sink.add(jsonEncode({'type': 'call-invite'}));

  await Future.delayed(const Duration(milliseconds: 800));

  // 3. 校验监视端收到的消息（成员加入后再请求快照）
  mon.sink.add(jsonEncode({'type': 'monitor-snapshot'}));
  await Future.delayed(const Duration(milliseconds: 400));
  final types = monMsgs.map((m) => m['type']).toList();
  results['收到快照'] = types.contains('monitor-snapshot');
  final snap = monMsgs.where((m) => m['type'] == 'monitor-snapshot').last;
  final rooms = (snap['rooms'] as List).cast<Map<String, dynamic>>();
  results['快照含房间 ABCD'] = rooms.any((r) => r['code'] == 'ABCD');
  results['快照含成员'] = rooms.isNotEmpty &&
      ((rooms.first['members'] as List).isNotEmpty);
  results['收到位置事件'] = monMsgs.any(
      (m) => m['type'] == 'monitor-loc' && m['lat'] == 39.9042);
  results['收到通话事件'] = monMsgs.any(
      (m) => m['type'] == 'monitor-event' && m['event'] == 'call-start');

  // 4. 公告广播 → 成员应收到 notice
  mon.sink.add(jsonEncode({'type': 'monitor-broadcast', 'room': 'abcd', 'text': '测试公告'}));

  // 5. 踢人指令 → 成员被断开
  mon.sink.add(jsonEncode({'type': 'monitor-kick', 'room': 'abcd', 'id': memId}));
  await kicked.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  results['踢出生效(成员被断开)'] = kicked.isCompleted;

  // 6. /monitor 页面静态服务
  final client = await HttpClient().get('localhost', 8888, '/monitor');
  final resp = await client.close();
  results['/monitor 返回 HTML'] =
      resp.statusCode == 200 && resp.headers.contentType?.subType == 'html';

  mem.sink.close(); mon.sink.close();
  var pass = 0;
  results.forEach((k, v) {
    print('${v ? "✅" : "❌"} $k');
    if (v) pass++;
  });
  exit(pass == results.length ? 0 : 1);
}
