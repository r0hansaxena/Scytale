import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_service.dart';
import '../services/profile_service.dart';

/// In-call UI: remote video full-screen, local preview in a corner,
/// accept/decline for incoming calls, mute/camera/hang-up controls.
/// Pops itself when the call ends.
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
        CallState.outgoing => 'Calling…',
        CallState.incoming =>
          _calls.audioOnly ? 'Incoming call' : 'Incoming video call',
        CallState.connected => _calls.audioOnly ? 'Voice call' : '',
        CallState.idle => 'Call ended',
      };

  @override
  Widget build(BuildContext context) {
    final peer = _calls.peer ?? '';
    final profile = peer.isEmpty ? null : ProfileService.instance.cached(peer);
    final displayName =
        (profile?.name.isNotEmpty ?? false) ? profile!.name : peer;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Remote video (or a placeholder while ringing / audio-only).
          if (_calls.state == CallState.connected)
            RTCVideoView(_calls.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          if (_calls.state != CallState.connected || _calls.audioOnly)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 48,
                    child: Text(
                      peer.length > 1 ? peer[1].toUpperCase() : '@',
                      style: const TextStyle(fontSize: 40),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(displayName,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 22)),
                  const SizedBox(height: 8),
                  Text(_statusText,
                      style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ),

          // Local preview.
          if (!_calls.audioOnly && _calls.state != CallState.incoming)
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

          // Peer name overlay during connected video call.
          if (_calls.state == CallState.connected && !_calls.audioOnly)
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: _calls.state == CallState.incoming
                  ? [
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
                    ]
                  : [
                      _RoundButton(
                        color: Colors.white24,
                        icon: _calls.muted ? Icons.mic_off : Icons.mic,
                        label: _calls.muted ? 'Unmute' : 'Mute',
                        onTap: _calls.toggleMute,
                      ),
                      const SizedBox(width: 24),
                      if (!_calls.audioOnly)
                        _RoundButton(
                          color: Colors.white24,
                          icon: _calls.cameraOff
                              ? Icons.videocam_off
                              : Icons.videocam,
                          label: _calls.cameraOff ? 'Camera on' : 'Camera off',
                          onTap: _calls.toggleCamera,
                        ),
                      if (!_calls.audioOnly) const SizedBox(width: 24),
                      _RoundButton(
                        color: Colors.red,
                        icon: Icons.call_end,
                        label: 'End',
                        onTap: () => _calls.hangup(),
                      ),
                    ],
            ),
          ),
        ],
      ),
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
