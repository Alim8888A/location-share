import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models.dart';
import 'socket_service.dart';

/// 网状语音通话：房间内任意成员互相建立 WebRTC 音频连接。
///
/// 握手规则（避免 offer 碰撞）：
/// 1. 任一成员 callInvite → 其他人弹出来电提示
/// 2. 接受者 callAccept → 所有人收到 call-accepted
/// 3. 对每一对已进入通话的成员，由 id 较小的一方发 offer（确定性规则）
class CallService extends ChangeNotifier {
  static final CallService instance = CallService._();

  CallService._() {
    final socket = SocketService.instance;
    socket.onCallSignal = _onSignal;
    socket.onMemberLeft = _onMemberLeft;
  }

  final SocketService socket = SocketService.instance;

  CallStatus status = CallStatus.idle;
  String? incomingFromName;
  DateTime? startedAt;
  bool muted = false;
  bool speakerOn = true;

  final Map<String, RTCPeerConnection> _pcs = {};
  MediaStream? _localStream;
  final Set<String> _inCallPeers = {};

  Timer? _elapsedTicker;
  Duration elapsed = Duration.zero;

  bool get inCall => status != CallStatus.idle;
  int get peerCount => _pcs.length;

  // ---------------- 发起 / 接听 ----------------

  Future<void> startCall() async {
    if (inCall) return;
    final ok = await _ensureLocalStream();
    if (!ok) return;
    _inCallPeers
      ..clear()
      ..add(socket.myId ?? '');
    status = CallStatus.inviting;
    startedAt = DateTime.now();
    _startTicker();
    socket.callInvite();
    notifyListeners();
  }

  Future<void> acceptIncoming() async {
    if (status != CallStatus.incoming) return;
    final ok = await _ensureLocalStream();
    if (!ok) return;
    _inCallPeers.add(socket.myId ?? '');
    status = CallStatus.active;
    startedAt ??= DateTime.now();
    _startTicker();
    socket.callAccept();
    notifyListeners();
  }

  void declineIncoming() {
    if (status != CallStatus.incoming) return;
    incomingFromName = null;
    status = CallStatus.idle;
    notifyListeners();
  }

  Future<void> hangUp() async {
    socket.callEnd();
    await _teardown();
  }

  // ---------------- 信令处理 ----------------

  void _onSignal(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'call-incoming':
        if (!inCall) {
          status = CallStatus.incoming;
          incomingFromName = msg['name'] as String?;
          notifyListeners();
        }
        break;
      case 'call-accepted':
        _onPeerAccepted(msg['from'] as String);
        break;
      case 'call-offer':
        _onOffer(msg['from'] as String, msg['sdp'] as String);
        break;
      case 'call-answer':
        _onAnswer(msg['from'] as String, msg['sdp'] as String);
        break;
      case 'call-ice':
        _onRemoteCandidate(msg['from'] as String, msg['candidate']);
        break;
      case 'call-ended':
        _teardown();
        break;
    }
  }

  void _onPeerAccepted(String peer) {
    if (peer == socket.myId) return;
    _inCallPeers.add(peer);
    if (!inCall) return; // 自己还没进入通话（未发起未接听）
    status = CallStatus.active;
    startedAt ??= DateTime.now();
    _startTicker();
    _connectIfSmallerId(peer);
    notifyListeners();
  }

  /// 确定性握手：id 较小的一方发起 offer
  void _connectIfSmallerId(String peer) {
    final myId = socket.myId;
    if (myId == null || _pcs.containsKey(peer)) return;
    if (myId.compareTo(peer) < 0) {
      _createOfferTo(peer);
    }
  }

  Future<void> _createOfferTo(String peer) async {
    try {
      final pc = await _createPc(peer);
      final offer = await pc.createOffer({'offerToReceiveAudio': 1});
      await pc.setLocalDescription(offer);
      socket.callOffer(peer, offer.sdp ?? '');
    } catch (e) {
      debugPrint('offer 失败: $e');
    }
  }

  Future<void> _onOffer(String from, String sdp) async {
    try {
      var pc = _pcs[from];
      pc ??= await _createPc(from);
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      final answer = await pc.createAnswer({'offerToReceiveAudio': 1});
      await pc.setLocalDescription(answer);
      socket.callAnswer(from, answer.sdp ?? '');
      status = CallStatus.active;
      startedAt ??= DateTime.now();
      _startTicker();
      notifyListeners();
    } catch (e) {
      debugPrint('answer 失败: $e');
    }
  }

  Future<void> _onAnswer(String from, String sdp) async {
    final pc = _pcs[from];
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    } catch (e) {
      debugPrint('setRemote 失败: $e');
    }
  }

  Future<void> _onRemoteCandidate(String from, dynamic candidate) async {
    if (candidate is! Map) return;
    final pc = _pcs[from];
    if (pc == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        candidate['sdpMLineIndex'] as int?,
      ));
    } catch (e) {
      debugPrint('addCandidate 失败: $e');
    }
  }

  // ---------------- PeerConnection ----------------

  Future<RTCPeerConnection> _createPc(String peer) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun.qq.com:3478'},
        {'urls': 'stun:stun.miwifi.com:3478'},
      ],
      'sdpSemantics': 'unified-plan',
    });
    _pcs[peer] = pc;

    final local = _localStream;
    if (local != null) {
      for (final track in local.getAudioTracks()) {
        await pc.addTrack(track, local);
      }
    }

    pc.onIceCandidate = (cand) {
      if (cand.candidate == null) return;
      socket.callIce(peer, cand.toMap());
    };
    pc.onConnectionState = (state) {
      debugPrint('PC[$peer] state=$state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _closePc(peer);
      }
    };
    pc.onTrack = (event) {
      // 远端音频轨道加入后自动播放（WebRTC 引擎处理）
      if (event.streams.isNotEmpty) {
        event.streams.first.getAudioTracks();
      }
    };
    return pc;
  }

  Future<void> _closePc(String peer) async {
    final pc = _pcs.remove(peer);
    try {
      await pc?.close();
    } catch (_) {}
  }

  Future<void> _teardown() async {
    _elapsedTicker?.cancel();
    for (final p in List<String>.from(_pcs.keys)) {
      await _closePc(p);
    }
    _inCallPeers.clear();
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    status = CallStatus.idle;
    incomingFromName = null;
    startedAt = null;
    elapsed = Duration.zero;
    muted = false;
    try {
      Helper.setSpeakerphoneOn(true);
    } catch (_) {}
    notifyListeners();
  }

  void _onMemberLeft() {
    // 离开房间的成员：直接断开与其的连接
    final liveIds = socket.members.keys.toSet();
    for (final peer in List<String>.from(_pcs.keys)) {
      if (!liveIds.contains(peer)) _closePc(peer);
    }
    _inCallPeers.removeWhere((p) => !liveIds.contains(p));
    if (_pcs.isEmpty && status != CallStatus.idle) {
      _teardown();
    } else {
      notifyListeners();
    }
  }

  // ---------------- 麦克风 / 扬声器 ----------------

  Future<bool> _ensureLocalStream() async {
    if (_localStream != null) return true;
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      return true;
    } catch (e) {
      debugPrint('获取麦克风失败: $e');
      return false;
    }
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _localStream?.getAudioTracks() ?? []) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleSpeaker() {
    speakerOn = !speakerOn;
    try {
      Helper.setSpeakerphoneOn(speakerOn);
    } catch (_) {}
    notifyListeners();
  }

  void _startTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (startedAt != null && inCall) {
        elapsed = DateTime.now().difference(startedAt!);
        notifyListeners();
      }
    });
  }
}
