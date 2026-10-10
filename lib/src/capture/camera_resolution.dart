import '../config/app_config.dart';

/// A concrete camera format expressed in absolute pixels.
///
/// The protocol never uses relative presets (`ResolutionPreset.medium` is a
/// relative tier and does not guarantee a pixel size), so every resolution that
/// crosses a boundary in this app is an explicit width/height pair.
class CameraResolution {
  const CameraResolution({required this.width, required this.height});

  final int width;
  final int height;

  int get pixelCount => width * height;

  double get aspectRatio => width / height;

  /// The smaller dimension, regardless of orientation.
  ///
  /// A resolution is a **size**, not an orientation: a camera held in portrait
  /// produces the same geometry transposed. Anything that compares two
  /// resolutions — what fits inside what, whether two share a shape —
  /// normalises to short-side/long-side first, so `1080x1920` and `1920x1080`
  /// are not mistaken for different things.
  int get shortSide => width <= height ? width : height;

  /// The larger dimension, regardless of orientation.
  int get longSide => width <= height ? height : width;

  String get label => '${width}x$height';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraResolution &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'CameraResolution($label)';
}

/// True when two resolutions describe the same shape, **whatever the
/// orientation**.
///
/// `1080x1920` and `1920x1080` are one shape rotated, not two: a camera that
/// produces one produces the other. Both are normalised to short-side/long-side
/// and cross-multiplied — no floating point, no rounding, and 1280x720 and
/// 1920x1080 come out equal exactly as they should.
bool sameShape(CameraResolution a, CameraResolution b) =>
    a.shortSide * b.longSide == b.shortSide * a.longSide;

/// Still-frame capture geometry and quality.
class CaptureConfig {
  const CaptureConfig({
    required this.width,
    required this.height,
    required this.quality,
  });

  final int width;
  final int height;
  final int quality;

  factory CaptureConfig.defaults() => const CaptureConfig(
    width: AppConfig.defaultWidth,
    height: AppConfig.defaultHeight,
    quality: AppConfig.defaultQuality,
  );

  CameraResolution get resolution =>
      CameraResolution(width: width, height: height);

  CaptureConfig copyWith({int? width, int? height, int? quality}) =>
      CaptureConfig(
        width: width ?? this.width,
        height: height ?? this.height,
        quality: quality ?? this.quality,
      );

  /// [copyWith] for a whole resolution, so a caller cannot pass a width
  /// without a matching height and end up with a geometry nobody chose.
  CaptureConfig copyWithResolution(CameraResolution resolution) =>
      CaptureConfig(
        width: resolution.width,
        height: resolution.height,
        quality: quality,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptureConfig &&
          other.width == width &&
          other.height == height &&
          other.quality == quality;

  @override
  int get hashCode => Object.hash(width, height, quality);

  @override
  String toString() => 'CaptureConfig(${width}x$height, q$quality)';
}
