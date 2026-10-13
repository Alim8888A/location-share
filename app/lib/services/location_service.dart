import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// 定位服务：权限管理 + 位置流（支持前台通知以保持后台更新）
class LocationService {
  /// 申请定位权限（含通知权限，用于后台定位通知）
  /// 返回是否获得精确定位权限
  static Future<bool> ensurePermissions() async {
    var status = await Permission.locationWhenInUse.status;
    if (!status.isGranted) {
      status = await Permission.locationWhenInUse.request();
    }
    if (!status.isGranted) return false;

    // Android 13+ 需要通知权限才能展示前台服务通知
    final notif = await Permission.notification.status;
    if (!notif.isGranted) {
      await Permission.notification.request();
    }
    return true;
  }

  /// 申请后台定位（可选，Android 10+ 会引导到系统设置）
  static Future<bool> requestBackground() async {
    final status = await Permission.locationAlways.request();
    return status.isGranted;
  }

  static Future<bool> isBackgroundGranted() =>
      Permission.locationAlways.isGranted;

  /// 最近一次已知位置（用于快速初始定位）
  static Future<Position?> lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// 实时位置流：距离变化 5 米或时间到 4 秒即上报
  static Stream<Position> positionStream({required bool background}) {
    return Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 4),
        timeLimit: const Duration(seconds: 30),
        foregroundNotificationConfig: background
            ? const ForegroundNotificationConfig(
                notificationTitle: '位置共享进行中',
                notificationText: '正在后台向房间成员共享你的位置',
                notificationChannelName: '后台定位',
                enableWakeLock: true,
                setOngoing: true,
              )
            : null,
      ),
    );
  }
}
