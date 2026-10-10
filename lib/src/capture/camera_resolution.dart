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
