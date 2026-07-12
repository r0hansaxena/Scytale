/// 1:1 video/audio calls.
///
/// Media: WebRTC — flows directly between the two peers, DTLS-SRTP
/// encrypted, never through any server (public STUN is used only to
/// discover reachable addresses; there is no TURN relay, so calls between
/// two very restrictive NATs may fail to connect).
///
/// Signaling: atProtocol notifications in the `scytale` namespace — the
/// same E2E encrypted channel as chat. Ephemeral keys, never put():
///   `call.<callId>.<seq>.scytale` sharedWith peer, value JSON:
///   {callId, type: offer|answer|candidate|bye, sdp?, candidate?, ...}
library;

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/navigation.dart';
import '../screens/call_screen.dart';
import 'message_service.dart';

enum CallState { idle, outgoing, incoming, connected }

class CallService extends ChangeNotifier {
  CallService._();
  static final CallService instance = CallService._();

  AtClient get _atClient => AtClientManager.getInstance().atClient;
  late String _me;

  CallState state = CallState.idle;
  String? peer;
  String? callId;
  bool muted = false;
  bool cameraOff = false;
  bool audioOnly = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _pendingOfferSdp;
  final List<RTCIceCandidate> _bufferedCandidates = [];
  bool _remoteDescSet = false;
  int _seq = 0;
  bool _screenOpen = false;
  bool _isCaller = false;
  DateTime? _connectedAt;

  StreamSubscription<AtNotification>? _subscription;

  static const Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  /// Call once after setCurrentAtSign.
  Future<void> start() async {
    _me = _atClient.getCurrentAtSign()!.toAtsign();
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _subscription?.cancel();
    _subscription = _atClient.notificationService
        .subscribe(regex: 'call\\..*\\.$appNamespace@', shouldDecrypt: true)
        .listen(_onSignal,
            onError: (e) => debugPrint('call signal stream error: $e'));
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _teardown(notifyPeer: state != CallState.idle);
  }

  // ---------------------------------------------------------------------
  // Signaling
  // ---------------------------------------------------------------------

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    final key = AtKey()
      ..key = 'call.$callId.${_seq++}'
      ..namespace = appNamespace
      ..sharedBy = _me
      ..sharedWith = to
      ..metadata = (Metadata()
        ..isEncrypted = true
        ..ttl = 60000);
    try {
      await _atClient.notificationService.notify(
        NotificationParams.forUpdate(key,
            value: jsonEncode(payload),
            notificationExpiry: const Duration(seconds: 45)),
        checkForFinalDeliveryStatus: false,
        waitForFinalDeliveryStatus: false,
      );
    } catch (e) {
      debugPrint('call signal send failed: $e');
    }
  }

  Future<void> _onSignal(AtNotification notification) async {
    Map<String, dynamic> payload;
    try {
      payload = (jsonDecode(notification.value ?? '{}') as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final from = notification.from.toAtsign();
    final type = payload['type'] as String?;
    final id = payload['callId'] as String?;
    if (type == null || id == null) return;

    switch (type) {
      case 'offer':
        if (state != CallState.idle) {
          // Already busy — reject this new call without touching ours.
          final busyId = callId;
          callId = id;
          await _send(from, {'callId': id, 'type': 'bye', 'reason': 'busy'});
          callId = busyId;
          return;
        }
        callId = id;
        peer = from;
        _pendingOfferSdp = payload['sdp'] as String?;
        state = CallState.incoming;
        notifyListeners();
        _openCallScreen();

      case 'answer':
        if (id != callId || state != CallState.outgoing) return;
        await _pc?.setRemoteDescription(
            RTCSessionDescription(payload['sdp'] as String?, 'answer'));
        _remoteDescSet = true;
        await _flushCandidates();
        state = CallState.connected;
        _connectedAt = DateTime.now();
        notifyListeners();

      case 'candidate':
        if (id != callId) return;
        final c = RTCIceCandidate(
          payload['candidate'] as String?,
          payload['sdpMid'] as String?,
          payload['sdpMLineIndex'] as int?,
        );
        if (_remoteDescSet && _pc != null) {
          await _pc!.addCandidate(c);
        } else {
          _bufferedCandidates.add(c);
        }

      case 'bye':
        if (id != callId) return;
        await _teardown(notifyPeer: false);
    }
  }

  Future<void> _flushCandidates() async {
    for (final c in _bufferedCandidates) {
      try {
        await _pc?.addCandidate(c);
      } catch (e) {
        debugPrint('addCandidate failed: $e');
      }
    }
    _bufferedCandidates.clear();
  }

  // ---------------------------------------------------------------------
  // Call control
  // ---------------------------------------------------------------------

  Future<void> startCall(String peerRaw) async {
    if (state != CallState.idle) return;
    peer = peerRaw.toAtsign();
    callId = const Uuid().v4();
    _isCaller = true;
    state = CallState.outgoing;
    notifyListeners();
    _openCallScreen();

    try {
      await _setupMediaAndPc();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      await _send(peer!, {
        'callId': callId,
        'type': 'offer',
        'sdp': offer.sdp,
      });
    } catch (e) {
      debugPrint('startCall failed: $e');
      await _teardown(notifyPeer: true);
    }
  }

  Future<void> accept() async {
    if (state != CallState.incoming || _pendingOfferSdp == null) return;
    try {
      await _setupMediaAndPc();
      await _pc!.setRemoteDescription(
          RTCSessionDescription(_pendingOfferSdp, 'offer'));
      _remoteDescSet = true;
      await _flushCandidates();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _send(peer!, {
        'callId': callId,
        'type': 'answer',
        'sdp': answer.sdp,
      });
      state = CallState.connected;
      _connectedAt = DateTime.now();
      notifyListeners();
    } catch (e) {
      debugPrint('accept failed: $e');
      await _teardown(notifyPeer: true);
    }
  }

  Future<void> decline() => _teardown(notifyPeer: true);

  Future<void> hangup() => _teardown(notifyPeer: true);

  void toggleMute() {
    muted = !muted;
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    cameraOff = !cameraOff;
    for (final t in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // WebRTC plumbing
  // ---------------------------------------------------------------------

  static const Map<String, dynamic> _audioConstraints = {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  };

  Future<void> _setupMediaAndPc() async {
    audioOnly = false;
    try {
      _localStream = await navigator.mediaDevices
          .getUserMedia({'audio': _audioConstraints, 'video': true});
    } catch (e) {
      // No camera (common on desktops) — fall back to audio-only.
      debugPrint('video capture unavailable, audio only: $e');
      audioOnly = true;
      _localStream = await navigator.mediaDevices
          .getUserMedia({'audio': _audioConstraints});
    }
    localRenderer.srcObject = _localStream;

    _pc = await createPeerConnection(_rtcConfig);
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
    _pc!.onIceCandidate = (candidate) {
      if (peer == null || candidate.candidate == null) return;
      _send(peer!, {
        'callId': callId,
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        notifyListeners();
      }
    };
    _pc!.onConnectionState = (s) {
      debugPrint('pc state: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _teardown(notifyPeer: false);
      }
    };
  }

  Future<void> _teardown({required bool notifyPeer}) async {
    if (notifyPeer && peer != null && callId != null) {
      await _send(peer!, {'callId': callId, 'type': 'bye'});
    }
    // The caller writes a call entry into the chat history (one side only,
    // so it appears exactly once for both people).
    if (_isCaller && peer != null && callId != null) {
      final label = audioOnly ? 'Voice call' : 'Video call';
      final summary = _connectedAt == null
          ? 'Missed ${label.toLowerCase()}'
          : '$label · ${_formatDuration(DateTime.now().difference(_connectedAt!))}';
      try {
        await MessageService.instance
            .sendMessage(peer!, summary, kind: 'call');
      } catch (e) {
        debugPrint('failed to record call entry: $e');
      }
    }
    for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      try {
        await t.stop();
      } catch (_) {}
    }
    await _localStream?.dispose();
    _localStream = null;
    await _pc?.close();
    _pc = null;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    _pendingOfferSdp = null;
    _bufferedCandidates.clear();
    _remoteDescSet = false;
    peer = null;
    callId = null;
    muted = false;
    cameraOff = false;
    _isCaller = false;
    _connectedAt = null;
    state = CallState.idle;
    notifyListeners();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }

  // ---------------------------------------------------------------------
  // UI hook
  // ---------------------------------------------------------------------

  void _openCallScreen() {
    if (_screenOpen) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _screenOpen = true;
    nav
        .push(MaterialPageRoute(builder: (_) => const CallScreen()))
        .whenComplete(() => _screenOpen = false);
  }
}
