import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A simple square image cropper: pan and zoom the image within a fixed
/// square frame, then confirm to get a cropped [outputSize]px PNG.
///
/// Returns the cropped bytes via Navigator.pop, or null if cancelled.
class CropScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final int outputSize;

  const CropScreen({super.key, required this.imageBytes, this.outputSize = 256});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  ui.Image? _image;
  double _viewport = 320;

  double _scale = 1;
  Offset _offset = Offset.zero;
  double _minScale = 1;
  final double _maxScaleFactor = 5;

  // Gesture baselines.
  late double _baseScale;
  late Offset _baseOffset;
  Offset _baseFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _image = frame.image);
  }

  void _fit() {
    final img = _image!;
    // Cover: fill the square, no gaps.
    _minScale = (_viewport / img.width) > (_viewport / img.height)
        ? _viewport / img.width
        : _viewport / img.height;
    _scale = _minScale;
    _offset = Offset(
      (_viewport - img.width * _scale) / 2,
      (_viewport - img.height * _scale) / 2,
    );
  }

  Offset _clamp(Offset o, double s) {
    final w = _image!.width * s;
    final h = _image!.height * s;
    return Offset(
      o.dx.clamp(_viewport - w, 0.0),
      o.dy.clamp(_viewport - h, 0.0),
    );
  }

  void _onScaleStart(ScaleStartDetails d) {
    _baseScale = _scale;
    _baseOffset = _offset;
    _baseFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final newScale =
        (_baseScale * d.scale).clamp(_minScale, _minScale * _maxScaleFactor);
    // Keep the source point under the initial focal fixed as we zoom.
    final srcUnderFocal = (_baseFocal - _baseOffset) / _baseScale;
    var newOffset = d.localFocalPoint - srcUnderFocal * newScale;
    newOffset = _clamp(newOffset, newScale);
    setState(() {
      _scale = newScale;
      _offset = newOffset;
    });
  }

  /// Zoom by a scroll delta, keeping the point under the cursor fixed.
  void _zoomAt(Offset focal, double delta) {
    final newScale =
        (_scale * (1 + delta / 500)).clamp(_minScale, _minScale * _maxScaleFactor);
    final srcUnderFocal = (focal - _offset) / _scale;
    final newOffset = _clamp(focal - srcUnderFocal * newScale, newScale);
    setState(() {
      _scale = newScale;
      _offset = newOffset;
    });
  }

  Future<void> _confirm() async {
    final img = _image!;
    final srcSide = _viewport / _scale;
    final src = Rect.fromLTWH(
      -_offset.dx / _scale,
      -_offset.dy / _scale,
      srcSide,
      srcSide,
    );
    final out = widget.outputSize.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(img, src, Rect.fromLTWH(0, 0, out, out), Paint());
    final picture = recorder.endRecording();
    final cropped =
        await picture.toImage(widget.outputSize, widget.outputSize);
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted) return;
    Navigator.pop(context, data!.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop photo'),
        actions: [
          if (_image != null)
            TextButton(
              onPressed: _confirm,
              child: const Text('Done'),
            ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: _image == null
            ? const CircularProgressIndicator()
            : LayoutBuilder(builder: (context, constraints) {
                final side =
                    (constraints.maxWidth < constraints.maxHeight
                            ? constraints.maxWidth
                            : constraints.maxHeight) -
                        48;
                final v = side.clamp(200.0, 420.0);
                if (v != _viewport || _scale == 1) {
                  _viewport = v;
                  _fit();
                }
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Listener(
                      onPointerSignal: (signal) {
                        if (signal is PointerScrollEvent) {
                          _zoomAt(signal.localPosition, -signal.scrollDelta.dy);
                        }
                      },
                      child: GestureDetector(
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: _viewport,
                            height: _viewport,
                            child: CustomPaint(
                              painter: _CropPainter(
                                image: _image!,
                                scale: _scale,
                                offset: _offset,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Drag to move · pinch or scroll to zoom',
                        style: TextStyle(color: Colors.white70)),
                  ],
                );
              }),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final double scale;
  final Offset offset;

  _CropPainter({required this.image, required this.scale, required this.offset});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final dst = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      image.width * scale,
      image.height * scale,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint(),
    );
    // Dim everything outside the circle so it reads as a circular frame.
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final mask = Path()
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.55));
    // Circle outline.
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.scale != scale || old.offset != offset || old.image != image;
}
