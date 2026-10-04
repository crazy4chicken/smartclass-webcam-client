import 'dart:io';
import 'dart:typed_data';

/// Owns the lifecycle of temporary capture files on disk.
///
/// On Windows `takePicture()` writes a file per frame. At 1 FPS that is 86,400
/// files a day, so every frame must be read and deleted immediately. Nothing
/// here is allowed to accumulate.
abstract interface class FrameStore {
  /// Reads the file's bytes and removes it.
  Future<Uint8List> readAndDelete(String path);

  /// Removes a file, ignoring the case where it is already gone.
  Future<void> delete(String path);
}

/// [FrameStore] backed by the real filesystem.
class IoFrameStore implements FrameStore {
  const IoFrameStore();

  @override
  Future<Uint8List> readAndDelete(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    await delete(path);
    return bytes;
  }

  @override
  Future<void> delete(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      // A missing or locked temp file must never break the capture loop.
    }
  }
}
