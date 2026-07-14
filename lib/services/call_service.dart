/// 1:1 video/voice calls.
///
/// Media: WebRTC — flows directly between the two peers, DTLS-SRTP
/// encrypted, never through any server (public STUN is used only to
/// discover reachable addresses; there is no TURN relay, so calls between
/// two very restrictive NATs may fail to connect).
///
/// Signaling: atProtocol notifications in the `scytale` namespace — the
/// same E2E encrypted channel as chat. Ephemeral keys:
///   `call.<callId>.<seq>.scytale` sharedWith peer, value JSON:
///   {callId, type: offer|answer|candidate|bye, sdp?, candidate?, video?}
///
/// A call may start as voice (no camera) and be upgraded to video mid-call
/// via renegotiation. The callee can pre-toggle mic/camera before accepting.
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

  /// Whether the call currently carries video (a voice call that has been
  /// upgraded becomes true). Drives the UI (avatar vs. video view).
  bool videoCall = false;

  /// Local media state.
  bool muted = false;
  bool cameraOff = false;

  /// Whether the remote peer is currently sending video. Driven by received
  /// video tracks and explicit `camera` signals, so we can show a clean
  /// avatar the moment the peer turns their camera off (instead of a frozen
  /// video texture).
  bool remoteCameraOn = false;

  /// Callee's pre-answer choices (editable while [state] == incoming).
  bool pendingMicOn = true;
  bool pendingCamOn = false;

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

  static const Map<String, dynamic> _audioConstraints = {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  };

  /// True when we have a live, enabled local camera track.
  bool get showLocalVideo =>
      (_localStream?.getVideoTracks().isNotEmpty ?? false) && !cameraOff;

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
        final sdp = payload['sdp'] as String?;
        final isVideo = payload['video'] as bool? ?? false;

        // Renegotiation of an in-progress call (e.g. peer upgraded to video).
        if (state == CallState.connected && id == callId) {
          try {
            await _pc!
                .setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
            final answer = await _pc!.createAnswer();
            await _pc!.setLocalDescription(answer);
            if (isVideo) videoCall = true;
            await _send(from, {
              'callId': id,
              'type': 'answer',
              'sdp': answer.sdp,
            });
            notifyListeners();
          } catch (e) {
            debugPrint('renegotiation failed: $e');
          }
          return;
        }

        if (state != CallState.idle) {
          // Busy — reject without disturbing our current call.
          final busyId = callId;
          callId = id;
          await _send(from, {'callId': id, 'type': 'bye', 'reason': 'busy'});
          callId = busyId;
          return;
        }

        // New incoming call.
        callId = id;
        peer = from;
        _pendingOfferSdp = sdp;
        videoCall = isVideo;
        pendingMicOn = true;
        pendingCamOn = isVideo; // default camera on only for video calls
        state = CallState.incoming;
        notifyListeners();
        _openCallScreen();

      case 'answer':
        if (id != callId) return;
        try {
          await _pc?.setRemoteDescription(
              RTCSessionDescription(payload['sdp'] as String?, 'answer'));
          _remoteDescSet = true;
          await _flushCandidates();
        } catch (e) {
          debugPrint('setRemoteDescription(answer) failed: $e');
        }
        if (state == CallState.outgoing) {
          state = CallState.connected;
          _connectedAt = DateTime.now();
        }
        notifyListeners();

      case 'camera':
        if (id != callId) return;
        remoteCameraOn = payload['on'] as bool? ?? false;
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

  /// Places a call. [video] chooses a video call (camera on) vs a voice call.
  Future<void> startCall(String peerRaw, {required bool video}) async {
    if (state != CallState.idle) return;
    peer = peerRaw.toAtsign();
    callId = const Uuid().v4();
    _isCaller = true;
    videoCall = video;
    state = CallState.outgoing;
    notifyListeners();
    _openCallScreen();

    try {
      await _setupMediaAndPc(captureVideo: video, micOn: true, camOn: video);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      await _send(peer!, {
        'callId': callId,
        'type': 'offer',
        'sdp': offer.sdp,
        'video': video,
      });
    } catch (e) {
      debugPrint('startCall failed: $e');
      await _teardown(notifyPeer: true);
    }
  }

  /// Accepts an incoming call using the callee's pre-answer mic/camera choices.
  Future<void> accept() async {
    if (state != CallState.incoming || _pendingOfferSdp == null) return;
    try {
      await _setupMediaAndPc(
        captureVideo: videoCall,
        micOn: pendingMicOn,
        camOn: pendingCamOn,
      );
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

  // Pre-answer toggles (while ringing).
  void togglePendingMic() {
    pendingMicOn = !pendingMicOn;
    notifyListeners();
  }

  void togglePendingCam() {
    pendingCamOn = !pendingCamOn;
    notifyListeners();
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  /// Turns the camera on/off. If there is no camera track yet (voice call or
  /// answered camera-off), this captures one and renegotiates — i.e. it
  /// upgrades the call to video.
  Future<void> toggleCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) {
      await _upgradeToVideo();
      return;
    }
    cameraOff = !cameraOff;
    for (final t in tracks) {
      t.enabled = !cameraOff;
    }
    _sendCameraState();
    notifyListeners();
  }

  /// Tell the peer whether we are currently sending video, so they can show
  /// our avatar instead of a frozen frame when we turn the camera off.
  void _sendCameraState() {
    if (peer == null || callId == null) return;
    _send(peer!, {'callId': callId, 'type': 'camera', 'on': showLocalVideo});
  }

  Future<void> _upgradeToVideo() async {
    if (_pc == null || _localStream == null) return;
    try {
      final camStream =
          await navigator.mediaDevices.getUserMedia({'video': true});
      final track = camStream.getVideoTracks().first;
      await _localStream!.addTrack(track);
      await _pc!.addTrack(track, _localStream!);
      localRenderer.srcObject = _localStream;
      cameraOff = false;
      videoCall = true;
      _sendCameraState();
      notifyListeners();

      // Renegotiate so the peer receives the new video track.
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      await _send(peer!, {
        'callId': callId,
        'type': 'offer',
        'sdp': offer.sdp,
        'video': true,
      });
    } catch (e) {
      debugPrint('upgrade to video failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // WebRTC plumbing
  // ---------------------------------------------------------------------

  Future<void> _setupMediaAndPc({
    required bool captureVideo,
    required bool micOn,
    required bool camOn,
  }) async {
    final wantVideo = captureVideo && camOn;
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': _audioConstraints,
        if (wantVideo) 'video': true,
      });
    } catch (e) {
      // Camera unavailable — capture audio only.
      debugPrint('camera capture failed, audio only: $e');
      _localStream =
          await navigator.mediaDevices.getUserMedia({'audio': _audioConstraints});
    }

    muted = !micOn;
    for (final t in _localStream!.getAudioTracks()) {
      t.enabled = micOn;
    }
    cameraOff = _localStream!.getVideoTracks().isEmpty;
    localRenderer.srcObject = _localStream;
    // The call screen was pushed before the camera finished initializing;
    // repaint now so the local preview appears without needing a toggle.
    notifyListeners();

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
      if (event.track.kind == 'video') {
        videoCall = true;
        remoteCameraOn = true;
      }
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
      }
      notifyListeners();
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
    // The caller records a call entry in the chat history (one side only,
    // so it appears exactly once for both people).
    if (_isCaller && peer != null && callId != null) {
      final label = videoCall ? 'Video call' : 'Voice call';
      final summary = _connectedAt == null
          ? 'Missed ${label.toLowerCase()}'
          : '$label · ${_formatDuration(DateTime.now().difference(_connectedAt!))}';
      try {
        await MessageService.instance.sendMessage(peer!, summary, kind: 'call');
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
    videoCall = false;
    remoteCameraOn = false;
    pendingMicOn = true;
    pendingCamOn = false;
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
