import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_service.dart';
import '../services/profile_service.dart';
import '../widgets/avatar.dart';

/// In-call UI. Incoming calls show mic/camera pre-toggles before Accept.
/// Connected calls show remote video (or an avatar for voice), a local
/// preview, and mute / camera(-or-switch-to-video) / end controls.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final CallService _calls = CallService.instance;

  @override
  void initState() {
    super.initState();
    _calls.addListener(_onUpdate);
  }

  @override
  void dispose() {
    _calls.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (!mounted) return;
    if (_calls.state == CallState.idle) {
      Navigator.of(context).maybePop();
    } else {
      setState(() {});
    }
  }

  String get _statusText => switch (_calls.state) {
        CallState.outgoing =>
          _calls.videoCall ? 'Calling (video)…' : 'Calling…',
        CallState.incoming =>
          _calls.videoCall ? 'Incoming video call' : 'Incoming voice call',
        CallState.connected => _calls.videoCall ? '' : 'Voice call',
        CallState.idle => 'Call ended',
      };

  @override
  Widget build(BuildContext context) {
    final peer = _calls.peer ?? '';
    final profile = peer.isEmpty ? null : ProfileService.instance.cached(peer);
    final displayName =
        (profile?.name.isNotEmpty ?? false) ? profile!.name : peer;
    final showRemoteVideo = _calls.state == CallState.connected &&
        _calls.remoteRenderer.srcObject != null &&
        _calls.remoteCameraOn;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (showRemoteVideo)
            RTCVideoView(_calls.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          // Avatar placeholder when there's no remote video yet.
          if (!showRemoteVideo)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Avatar(atsign: peer, profile: profile, radius: 48),
                  const SizedBox(height: 16),
                  Text(displayName,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 22)),
                  const SizedBox(height: 8),
                  Text(_statusText,
                      style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ),

          // Local preview (only when our camera is live).
          if (_calls.showLocalVideo)
            Positioned(
              right: 16,
              top: 16,
              width: 160,
              height: 120,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  color: Colors.grey.shade900,
                  child: RTCVideoView(_calls.localRenderer, mirror: true),
                ),
              ),
            ),

          if (showRemoteVideo)
            Positioned(
              left: 16,
              top: 16,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(displayName,
                    style: const TextStyle(color: Colors.white)),
              ),
            ),

          // Controls.
          Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: _calls.state == CallState.incoming
                ? _incomingControls()
                : _connectedControls(),
          ),
        ],
      ),
    );
  }

  Widget _incomingControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pre-answer mic/camera choices.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundButton(
              color: _calls.pendingMicOn ? Colors.white24 : Colors.red,
              icon: _calls.pendingMicOn ? Icons.mic : Icons.mic_off,
              label: _calls.pendingMicOn ? 'Mic on' : 'Mic off',
              onTap: _calls.togglePendingMic,
            ),
            const SizedBox(width: 24),
            _RoundButton(
              color: _calls.pendingCamOn ? Colors.white24 : Colors.red,
              icon: _calls.pendingCamOn ? Icons.videocam : Icons.videocam_off,
              label: _calls.pendingCamOn ? 'Camera on' : 'Camera off',
              onTap: _calls.togglePendingCam,
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundButton(
              color: Colors.green,
              icon: Icons.call,
              label: 'Accept',
              onTap: () => _calls.accept(),
            ),
            const SizedBox(width: 48),
            _RoundButton(
              color: Colors.red,
              icon: Icons.call_end,
              label: 'Decline',
              onTap: () => _calls.decline(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _connectedControls() {
    final hasCamera = _calls.showLocalVideo;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(
          color: Colors.white24,
          icon: _calls.muted ? Icons.mic_off : Icons.mic,
          label: _calls.muted ? 'Unmute' : 'Mute',
          onTap: _calls.toggleMute,
        ),
        const SizedBox(width: 24),
        _RoundButton(
          color: Colors.white24,
          icon: hasCamera ? Icons.videocam : Icons.videocam_off,
          // No camera track yet → this starts video (upgrade). Otherwise it
          // toggles the existing camera.
          label: hasCamera
              ? 'Camera off'
              : (_calls.videoCall ? 'Camera on' : 'Start video'),
          onTap: _calls.toggleCamera,
        ),
        const SizedBox(width: 24),
        _RoundButton(
          color: Colors.red,
          icon: Icons.call_end,
          label: 'End',
          onTap: () => _calls.hangup(),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _RoundButton({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
