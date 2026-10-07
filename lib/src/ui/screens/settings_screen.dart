import 'dart:async';

import 'package:flutter/material.dart';

import '../../backend/backend_gateway.dart';
import '../../backend/device_credentials.dart';
import '../../backend/health_probe.dart';
import '../../config/app_config.dart';
import '../../config/connection_settings.dart';
import '../widgets/status_bar_overlay.dart';

/// Where an installer points the device at a backend and gives it an identity.
///
/// This exists so a wrong address is a two-minute fix on the device instead of
/// a rebuild: before it, `BASE_URL` / `DEVICE_ID` / `DEVICE_TOKEN` were
/// compile-time only.
///
/// Only the **connection** half is editable. Capture parameters (fps,
/// resolution, quality) are not here: they are not things that change when the
/// server changes, and fps and resolution are announced at registration, so
/// editing them would have to rebuild the announcement too.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initial,
    required this.onSaved,
    this.isRecording = false,
    this.linkState = LinkState.idle,
    this.probe,
  });

  /// Seeds the fields.
  final ConnectionSettings initial;

  /// Called after the screen pops, with the trimmed and normalised values.
  final Future<void> Function(ConnectionSettings next) onSaved;

  /// Shows the "saving will cut the recording" banner.
  final bool isRecording;

  /// Shown at the bottom so an operator can confirm the new address connected
  /// without going back to the kiosk screen.
  final LinkState linkState;

  /// Injected in tests; a real HTTP probe is used otherwise.
  final HealthProbe? probe;

  // Keys for tests. Each piece of text gets its own key so a failure points at
  // the right field, and so no two widgets ever carry the same string.
  static const Key urlFieldKey = Key('settings-url');
  static const Key deviceIdFieldKey = Key('settings-device-id');
  static const Key tokenFieldKey = Key('settings-token');
  static const Key tokenVisibilityKey = Key('settings-token-visibility');
  static const Key urlErrorKey = Key('settings-url-error');
  static const Key deviceIdErrorKey = Key('settings-device-id-error');
  static const Key tokenErrorKey = Key('settings-token-error');
  static const Key saveKey = Key('settings-save');
  static const Key resetKey = Key('settings-reset');
  static const Key clearCredentialsKey = Key('settings-clear-credentials');
  static const Key probeKey = Key('settings-probe');
  static const Key probeResultKey = Key('settings-probe-result');
  static const Key recordingBannerKey = Key('settings-recording-banner');
  static const Key linkStatusKey = Key('settings-link-status');

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _idController;
  late final TextEditingController _tokenController;

  late final HealthProbe _probe;

  String? _urlError;
  String? _deviceIdError;
  String? _tokenError;
  bool _canSave = false;

  bool _obscureToken = true;

  bool _probing = false;
  HealthProbeResult? _probeResult;

  @override
  void initState() {
    super.initState();
    _probe = widget.probe ?? HttpHealthProbe();

    _urlController = TextEditingController(
      text: widget.initial.baseUrl.toString(),
    );
    _idController = TextEditingController(
      text: widget.initial.credentials?.deviceId ?? '',
    );
    _tokenController = TextEditingController(
      text: widget.initial.credentials?.deviceToken ?? '',
    );

    _apply(_evaluate());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _idController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  /// Recomputes every error. Called on each keystroke so the save button is
  /// disabled while the input is bad, rather than complaining after a tap.
  void _revalidate() => setState(() => _apply(_evaluate()));

  /// Assignment without `setState`, for use from [initState].
  void _apply(({String? url, String? deviceId, String? token}) errors) {
    _urlError = errors.url;
    _deviceIdError = errors.deviceId;
    _tokenError = errors.token;
    _canSave =
        _urlError == null && _deviceIdError == null && _tokenError == null;
  }

  ({String? url, String? deviceId, String? token}) _evaluate() {
    final url = validateBaseUrl(_urlController.text);
    final typed = DeviceCredentials(
      deviceId: _idController.text.trim(),
      deviceToken: _tokenController.text.trim(),
    );

    final hasId = typed.deviceId.isNotEmpty;
    final hasToken = typed.deviceToken.isNotEmpty;

    String? idError;
    String? tokenError;
    if (hasId != hasToken) {
      // Half a credential is always a mistake, and the useful place to say so
      // is the field that is empty. Flagging the half the operator already
      // filled in correctly would just be noise.
      const incomplete = '设备 ID 与设备令牌需要同时填写';
      if (!hasId) idError = incomplete;
      if (!hasToken) tokenError = incomplete;
    } else {
      if (hasId && !typed.hasValidDeviceId) {
        idError = '设备 ID 应是服务端签发的 26 位 ULID';
      }
      if (hasToken && !typed.hasValidDeviceToken) {
        tokenError = '设备令牌应以 wdt_ 开头，后接 43 个字符';
      }
    }

    return (
      url: url.isOk ? null : url.message,
      deviceId: idError,
      token: tokenError,
    );
  }

  /// The value to save, or null while anything is invalid.
  ConnectionSettings? _build() {
    if (!_canSave) return null;
    final url = validateBaseUrl(_urlController.text);
    final typed = DeviceCredentials(
      deviceId: _idController.text.trim(),
      deviceToken: _tokenController.text.trim(),
    );
    return ConnectionSettings(
      baseUrl: url.uri!,
      credentials: typed.isConfigured ? typed : null,
    );
  }

  void _save() {
    final next = _build();
    if (next == null) return;

    // Capture the callback before popping: the State outlives the pop by a
    // frame, but reading `widget` afterwards is needless risk.
    final onSaved = widget.onSaved;
    Navigator.of(context).pop();
    // Deliberately not awaited: the kiosk comes back immediately and the
    // reconnect reports through the status bar.
    unawaited(onSaved(next));
  }

  /// Puts the address back to the build-time default. Credentials are left
  /// alone — they belong to a device, not to an address.
  void _resetToDefault() {
    final fallback = validateBaseUrl(AppConfig.baseUrl);
    _urlController.text = fallback.isOk
        ? fallback.uri!.toString()
        : defaultBaseUrl;
    _revalidate();
  }

  /// Empties the credential fields. Saving is still a separate, deliberate
  /// step, so this cannot wipe a working device by accident.
  void _clearCredentials() {
    _idController.clear();
    _tokenController.clear();
    _revalidate();
  }

  Future<void> _testConnection() async {
    final url = validateBaseUrl(_urlController.text);
    if (!url.isOk) return;

    setState(() {
      _probing = true;
      _probeResult = null;
    });

    final result = await _probe.probe(url.uri!);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('后端设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (widget.isRecording) _recordingBanner(),
            _sectionTitle('后端'),
            TextField(
              key: SettingsScreen.urlFieldKey,
              controller: _urlController,
              onChanged: (_) => _revalidate(),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '后端地址',
                hintText: 'http://192.168.1.20:8080',
                helperText: '不写 http:// 会自动补全；ws:// 按 http:// 处理',
              ),
            ),
            _errorText(SettingsScreen.urlErrorKey, _urlError),

            const SizedBox(height: 24),
            _sectionTitle('设备凭据'),
            TextField(
              key: SettingsScreen.deviceIdFieldKey,
              controller: _idController,
              onChanged: (_) => _revalidate(),
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '设备 ID',
                hintText: '26 位 ULID',
              ),
            ),
            _errorText(SettingsScreen.deviceIdErrorKey, _deviceIdError),

            const SizedBox(height: 12),
            TextField(
              key: SettingsScreen.tokenFieldKey,
              controller: _tokenController,
              onChanged: (_) => _revalidate(),
              autocorrect: false,
              // Masked by default: this is a live credential, and it is written
              // to plain-text preferences.
              obscureText: _obscureToken,
              decoration: InputDecoration(
                labelText: '设备令牌',
                hintText: 'wdt_…',
                suffixIcon: IconButton(
                  key: SettingsScreen.tokenVisibilityKey,
                  tooltip: _obscureToken ? '显示令牌' : '隐藏令牌',
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
            ),
            _errorText(SettingsScreen.tokenErrorKey, _tokenError),

            const SizedBox(height: 24),
            _sectionTitle('操作'),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: SettingsScreen.probeKey,
                  onPressed: _probing ? null : _testConnection,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(_probing ? '测试中…' : '测试连接'),
                ),
                FilledButton(
                  key: SettingsScreen.saveKey,
                  onPressed: _canSave ? _save : null,
                  child: const Text('保存并重连'),
                ),
                OutlinedButton(
                  key: SettingsScreen.resetKey,
                  onPressed: _resetToDefault,
                  child: const Text('恢复默认'),
                ),
                TextButton(
                  key: SettingsScreen.clearCredentialsKey,
                  onPressed: _clearCredentials,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFEF5350),
                  ),
                  child: const Text('清空凭据'),
                ),
              ],
            ),

            if (_probeResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _probeResult!.summary,
                  key: SettingsScreen.probeResultKey,
                  // Three ways out, not two. Green means the health route
                  // answered 200. Amber means something answered but not that
                  // route — the address is right and the link is unaffected,
                  // which is a very different situation from a dead address,
                  // and collapsing the two is what made a connected device
                  // look broken.
                  style: TextStyle(
                    fontSize: 12,
                    color: switch (_probeResult!) {
                      (final r) when r.healthy => const Color(0xFF81C784),
                      (final r) when r.reachable => const Color(0xFFFFB300),
                      _ => const Color(0xFFEF9A9A),
                    },
                  ),
                ),
              ),

            const SizedBox(height: 28),
            Text(
              '当前链路：${linkStateLabel(widget.linkState)}',
              key: SettingsScreen.linkStatusKey,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /// Rendered as a plain [Text] with its own key rather than through
  /// `InputDecoration.errorText`: two widgets carrying the same string is the
  /// exact thing that made `find.textContaining` ambiguous before.
  Widget _errorText(Key key, String? message) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Text(
        message,
        key: key,
        style: const TextStyle(color: Color(0xFFEF9A9A), fontSize: 12),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    ),
  );

  /// The honest warning: the disconnect really does fail the stream server-side.
  Widget _recordingBanner() => Container(
    key: SettingsScreen.recordingBannerKey,
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFB300).withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFFFB300)),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, color: Color(0xFFFFB300), size: 20),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            '保存会中断当前录制，服务端会把该流标记为 failed。',
            style: TextStyle(fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
