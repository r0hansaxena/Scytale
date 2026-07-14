import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/models.dart';

/// A circular avatar that shows the profile picture if one is set, otherwise
/// the first letter of the Atsign.
class Avatar extends StatelessWidget {
  final String atsign;
  final Profile? profile;
  final double radius;

  const Avatar({
    super.key,
    required this.atsign,
    this.profile,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final b64 = profile?.avatarB64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        return CircleAvatar(
          radius: radius,
          backgroundImage: MemoryImage(base64Decode(b64)),
        );
      } catch (_) {
        // Fall through to the letter avatar on a bad image.
      }
    }
    return CircleAvatar(
      radius: radius,
      child: Text(
        atsign.length > 1 ? atsign[1].toUpperCase() : '@',
        style: TextStyle(fontSize: radius * 0.8),
      ),
    );
  }
}

/// Decodes, downscales (proportionally to [maxDim] wide), and re-encodes an
/// image to PNG so avatars stay small enough for the public profile AtKey.
Future<Uint8List> downscaleImage(Uint8List input, {int maxDim = 256}) async {
  final codec = await ui.instantiateImageCodec(input, targetWidth: maxDim);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
