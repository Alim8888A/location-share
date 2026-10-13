import 'package:flutter_test/flutter_test.dart';

import 'package:location_share/models.dart';

void main() {
  test('生成房间码为6位且无易混淆字符', () {
    final code = generateRoomCode();
    expect(code.length, 6);
    expect(code, equals(code.toUpperCase()));
    expect(code.contains('O'), isFalse);
    expect(code.contains('I'), isFalse);
    expect(code.contains('0'), isFalse);
    expect(code.contains('1'), isFalse);
  });

  test('成员按 id 稳定取色', () {
    expect(colorForId('abc'), colorForId('abc'));
    expect(colorForId('abc'), isNot(colorForId('xyz')));
  });
}
