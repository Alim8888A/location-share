import 'dart:ui';

/// 房间内成员的实时状态
class MemberState {
  final String id;
  final String name;
  double? lat;
  double? lng;
  double? heading; // 朝向（度）
  double? accuracy; // 定位精度（米）
  int? ts; // 最近更新时间戳(ms)

  MemberState({required this.id, required this.name});

  bool get hasLocation => lat != null && lng != null;

  factory MemberState.fromJson(Map<String, dynamic> j) => MemberState(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '成员',
      );
}

/// 通话状态
enum CallStatus { idle, inviting, incoming, active }

/// 成员标识色（按 id 稳定取色）
const List<Color> memberColors = [
  Color(0xFF3D5AFE),
  Color(0xFFE53935),
  Color(0xFF43A047),
  Color(0xFFFB8C00),
  Color(0xFF8E24AA),
  Color(0xFF00ACC1),
  Color(0xFF6D4C41),
  Color(0xFFC2185B),
  Color(0xFF7CB342),
  Color(0xFFF4511E),
];

Color colorForId(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return memberColors[h % memberColors.length];
}

/// 生成房间码（6位大写字母数字，去掉易混淆字符）
String generateRoomCode() {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  final r = DateTime.now().microsecondsSinceEpoch;
  var seed = r ^ (r >> 13);
  String next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return chars[seed % chars.length];
  }

  return List.generate(6, (_) => next()).join();
}
