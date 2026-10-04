/// The long-lived credential a device presents on the device plane.
///
/// Both halves are issued by the server, never by the client:
/// `device_id` comes from `POST /api/devices` and `device_token` from that
/// response (or a later `POST /api/devices/{id}/token` rotation). The token's
/// SHA-256 hash is all the server stores, so a leaked token can only be fixed
/// by rotating it.
class DeviceCredentials {
  const DeviceCredentials({required this.deviceId, required this.deviceToken});

  /// A 26-character ULID. The server looks it up by this exact string, with no
  /// case folding.
  final String deviceId;

  /// `wdt_` followed by 43 base64url characters (32 random bytes, no padding).
  final String deviceToken;

  /// Whether [deviceId] has the shape of a server-issued ULID.
  bool get hasValidDeviceId => _ulid.hasMatch(deviceId);

  /// Whether [deviceToken] has the shape of a server-issued device token.
  bool get hasValidDeviceToken => _token.hasMatch(deviceToken);

  /// Pre-flight check only.
  ///
  /// The server answers a wrong-shape and a wrong-value credential with the
  /// same `401`, so checking the shape locally turns a confusing "device
  /// authentication failed" into a clear "this looks like a typo" before a
  /// single request goes out.
  bool get looksValid => hasValidDeviceId && hasValidDeviceToken;

  /// True when both halves are present, whether or not they look right.
  bool get isConfigured => deviceId.isNotEmpty && deviceToken.isNotEmpty;

  /// Crockford base32 ULID: 26 characters, excluding I, L, O and U.
  static final RegExp _ulid = RegExp(r'^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{26}$');

  static final RegExp _token = RegExp(r'^wdt_[A-Za-z0-9_-]{43}$');

  /// Returns the credential unchanged if it looks valid, otherwise throws.
  ///
  /// Used at bootstrap so a misconfiguration fails loudly at startup instead
  /// of as a silent reconnect loop.
  DeviceCredentials validate() {
    if (!isConfigured) {
      throw StateError(
        'device credentials are missing: set DEVICE_ID and DEVICE_TOKEN, or '
        'provision them through the credential store',
      );
    }
    if (!hasValidDeviceId) {
      throw StateError(
        'DEVICE_ID "${_redact(deviceId)}" is not a 26-character ULID',
      );
    }
    if (!hasValidDeviceToken) {
      throw StateError(
        'DEVICE_TOKEN must be "wdt_" followed by 43 base64url characters',
      );
    }
    return this;
  }

  /// Never logs a credential in full.
  static String _redact(String value) =>
      value.length <= 8 ? '***' : '${value.substring(0, 8)}…';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceCredentials &&
          other.deviceId == deviceId &&
          other.deviceToken == deviceToken;

  @override
  int get hashCode => Object.hash(deviceId, deviceToken);

  /// Deliberately does not print the token.
  @override
  String toString() =>
      'DeviceCredentials(deviceId: ${_redact(deviceId)}, token: ***)';
}
