import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models.dart';
import '../services/call_service.dart';
import '../services/location_service.dart';
import '../services/socket_service.dart';

const _dist = Distance();

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.roomCode});

  final String roomCode;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _socket = SocketService.instance;
  final _call = CallService.instance;
  final _mapCtrl = MapController();

  StreamSubscription? _posSub;
  Position? _myPos;
  bool _sharing = false;
  bool _following = true;
  bool _leaving = false;
  bool _background = false;

  @override
  void initState() {
    super.initState();
    _startSharing();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  // ---------------- 位置共享 ----------------

  Future<void> _startSharing() async {
    _background = await LocationService.isBackgroundGranted();
    final last = await LocationService.lastKnown();
    if (last != null) {
      _myPos = last;
      _socket.sendLocation(
          lat: last.latitude,
          lng: last.longitude,
          heading: last.heading,
          accuracy: last.accuracy);
    }
    if (mounted) setState(() => _sharing = true);
    _posSub?.cancel();
    _posSub = LocationService.positionStream(background: _background).listen(
      (pos) {
        _myPos = pos;
        _socket.sendLocation(
            lat: pos.latitude,
            lng: pos.longitude,
            heading: pos.heading,
            accuracy: pos.accuracy);
        if (mounted) {
          setState(() {});
          if (_following) {
            _mapCtrl.move(LatLng(pos.latitude, pos.longitude), 16);
          }
        }
      },
      onError: (_) {},
    );
  }

  Future<void> _stopSharing() async {
    await _posSub?.cancel();
    _posSub = null;
    if (mounted) setState(() => _sharing = false);
  }

  void _toggleSharing() {
    _sharing ? _stopSharing() : _startSharing();
  }

  // ---------------- 离开房间 ----------------

  Future<bool> _confirmLeave() async {
    final r = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('退出房间？'),
        content: const Text('退出后将停止共享位置并断开连接'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出')),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _leave() async {
    if (_leaving) return;
    if (!await _confirmLeave()) return;
    _leaving = true;
    await _posSub?.cancel();
    if (_call.inCall) await _call.hangUp();
    _socket.leaveRoom();
    if (mounted) Navigator.of(context).pop();
  }

  // ---------------- 地图元素 ----------------

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    for (final m in _socket.members.values) {
      if (!m.hasLocation) continue;
      final isMe = m.id == _socket.myId;
      markers.add(Marker(
        point: LatLng(m.lat!, m.lng!),
        width: 44,
        height: 60,
        alignment: Alignment.topCenter,
        child: _MemberPin(
          color: colorForId(m.id),
          name: isMe ? '我' : m.name,
          heading: m.heading,
          isMe: isMe,
        ),
      ));
    }
    return markers;
  }

  List<CircleMarker> _buildAccuracyCircles() {
    final circles = <CircleMarker>[];
    for (final m in _socket.members.values) {
      if (!m.hasLocation || m.accuracy == null) continue;
      circles.add(CircleMarker(
        point: LatLng(m.lat!, m.lng!),
        radius: m.accuracy!.clamp(10.0, 200.0),
        useRadiusInMeter: true,
        color: colorForId(m.id).withValues(alpha: 0.10),
        borderStrokeWidth: 1,
        borderColor: colorForId(m.id).withValues(alpha: 0.35),
      ));
    }
    return circles;
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave()) _leave();
      },
      child: Scaffold(
        body: ListenableBuilder(
          listenable: Listenable.merge([_socket, _call]),
          builder: (context, _) => Stack(
            children: [
              FlutterMap(
                mapController: _mapCtrl,
                options: MapOptions(
                  initialCenter: _myPos != null
                      ? LatLng(_myPos!.latitude, _myPos!.longitude)
                      : const LatLng(39.9042, 116.4074),
                  initialZoom: 15,
                  onPositionChanged: (pos, hasGesture) {
                    if (hasGesture && _following) {
                      setState(() => _following = false);
                    }
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.locshare.location_share',
                  ),
                  CircleLayer(circles: _buildAccuracyCircles()),
                  MarkerLayer(markers: _buildMarkers()),
                  RichAttributionWidget(
                    attributions: [TextSourceAttribution('© OpenStreetMap')],
                  ),
                ],
              ),

              // 顶部房间信息
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child:
                      _RoomBanner(roomCode: widget.roomCode, onLeave: _leave),
                ),
              ),

              // 断线提示
              if (!_socket.isConnected)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 108,
                  child: Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.wifi_off_rounded,
                              size: 18,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _socket.lastError ?? '正在连接服务器…',
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _socket.reconnectNow(),
                            child: const Text('重连'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 右侧按钮
              Positioned(
                right: 12,
                bottom: 128,
                child: Column(
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'locate',
                      onPressed: () {
                        if (_myPos == null) return;
                        setState(() => _following = true);
                        _mapCtrl.move(
                            LatLng(_myPos!.latitude, _myPos!.longitude), 16);
                      },
                      child: Icon(_following
                          ? Icons.my_location
                          : Icons.location_searching),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'members',
                      onPressed: _showMembersSheet,
                      child: Badge(
                        label: Text('${_socket.members.length}'),
                        child: const Icon(Icons.people_rounded),
                      ),
                    ),
                  ],
                ),
              ),

              // 底部：共享开关 + 通话
              Positioned(
                left: 12,
                right: 12,
                bottom: 16,
                child: _BottomBar(
                  sharing: _sharing,
                  onToggleSharing: _toggleSharing,
                  call: _call,
                ),
              ),

              // 来电面板
              if (_call.status == CallStatus.incoming)
                const Positioned.fill(child: _IncomingCallPanel()),
            ],
          ),
        ),
      ),
    );
  }

  void _showMembersSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) {
        final me = _myPos == null
            ? null
            : LatLng(_myPos!.latitude, _myPos!.longitude);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text('房间成员（${_socket.members.length}）',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              for (final m in _socket.members.values)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: colorForId(m.id),
                    child: Text(
                      _initial(m.id == _socket.myId ? '我' : m.name),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  title: Text(m.id == _socket.myId ? '${m.name}（我）' : m.name),
                  subtitle: Text(m.hasLocation ? '已共享位置' : '未共享位置'),
                  trailing: (m.hasLocation && me != null && m.id != _socket.myId)
                      ? Text(
                          '${(_dist.as(LengthUnit.Meter, me, LatLng(m.lat!, m.lng!)) / 1000).toStringAsFixed(1)} km',
                          style: Theme.of(context).textTheme.bodyMedium,
                        )
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }

  static String _initial(String name) {
    if (name.isEmpty) return '?';
    return String.fromCharCode(name.runes.first).toUpperCase();
  }
}

// ==================== 组件 ====================

class _RoomBanner extends StatelessWidget {
  const _RoomBanner({required this.roomCode, required this.onLeave});

  final String roomCode;
  final Future<void> Function() onLeave;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.meeting_room_rounded, color: cs.primary),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('房间码',
                          style: Theme.of(context).textTheme.labelSmall),
                      Text(roomCode,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2)),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 20),
                    tooltip: '复制房间码',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: roomCode));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('已复制房间码 $roomCode'),
                          duration: const Duration(seconds: 1)));
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Card(
          elevation: 2,
          child: IconButton(
            icon: Icon(Icons.logout_rounded, color: cs.error),
            tooltip: '退出房间',
            onPressed: onLeave,
          ),
        ),
      ],
    );
  }
}

class _MemberPin extends StatelessWidget {
  const _MemberPin({
    required this.color,
    required this.name,
    required this.heading,
    required this.isMe,
  });

  final Color color;
  final String name;
  final double? heading;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          constraints: const BoxConstraints(maxWidth: 44),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
        Transform.rotate(
          angle: ((heading ?? 0) * 3.14159265 / 180),
          child: Icon(
            isMe ? Icons.navigation_rounded : Icons.person_pin_circle_rounded,
            color: color,
            size: 32,
            shadows: const [
              Shadow(color: Colors.black26, blurRadius: 4, offset: Offset(1, 1))
            ],
          ),
        ),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.sharing,
    required this.onToggleSharing,
    required this.call,
  });

  final bool sharing;
  final VoidCallback onToggleSharing;
  final CallService call;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        final showCallUI = call.status == CallStatus.active ||
            call.status == CallStatus.inviting;
        return Card(
          elevation: 4,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: showCallUI
                ? Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: call.toggleMute,
                        icon: Icon(call.muted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded),
                        tooltip: call.muted ? '取消静音' : '静音',
                      ),
                      IconButton.filledTonal(
                        onPressed: call.toggleSpeaker,
                        icon: Icon(call.speakerOn
                            ? Icons.volume_up_rounded
                            : Icons.hearing_disabled_rounded),
                        tooltip: '扬声器',
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              call.status == CallStatus.inviting
                                  ? '等待成员接听…'
                                  : '通话中',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(_fmt(call.elapsed),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: cs.primary)),
                          ],
                        ),
                      ),
                      IconButton.filled(
                        style: FilledButton.styleFrom(
                            backgroundColor: cs.error,
                            foregroundColor: cs.onError),
                        onPressed: call.hangUp,
                        icon: const Icon(Icons.call_end_rounded),
                        tooltip: '挂断',
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: onToggleSharing,
                          icon: Icon(sharing
                              ? Icons.location_on_rounded
                              : Icons.location_off_rounded),
                          label: Text(sharing
                              ? '正在共享位置 · 点击停止'
                              : '位置共享已停止 · 点击开启'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: '发起语音通话',
                        onPressed: () => call.startCall(),
                        icon: const Icon(Icons.call_rounded),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _IncomingCallPanel extends StatelessWidget {
  const _IncomingCallPanel();

  @override
  Widget build(BuildContext context) {
    final call = CallService.instance;
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: Colors.black54,
      child: Center(
        child: Card(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.ring_volume_rounded, size: 48),
                const SizedBox(height: 12),
                Text('${call.incomingFromName ?? '房间成员'} 邀请你加入语音通话',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Column(
                      children: [
                        IconButton.filledTonal(
                          style: FilledButton.styleFrom(
                              backgroundColor: cs.errorContainer),
                          iconSize: 36,
                          onPressed: call.declineIncoming,
                          icon: Icon(Icons.call_end_rounded, color: cs.error),
                        ),
                        const Text('拒绝'),
                      ],
                    ),
                    Column(
                      children: [
                        IconButton.filled(
                          style:
                              FilledButton.styleFrom(backgroundColor: Colors.green),
                          iconSize: 36,
                          onPressed: call.acceptIncoming,
                          icon: const Icon(Icons.call_rounded),
                        ),
                        const Text('接听'),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
