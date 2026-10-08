import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/capability_bootstrap.dart';
import '../../backend/backend_gateway.dart';
import '../../backend/device_credentials.dart';
import '../../backend/health_probe.dart';
import '../../capture/capability_report.dart';
import '../../config/app_config.dart';
import '../../config/connection_settings.dart';
import '../widgets/status_bar_overlay.dart';
import 'capabilities_screen.dart';

/// Where an installer points the device at a backend and gives it an identity.
///
/// This exists so a wrong address is a two-minute fix on the device instead of
/// a rebuild: before it, `BASE_URL` / `DEVICE_ID` / `DEVICE_TOKEN` were
/// compile-time only.
///
/// Only the **connection** half is editable here, plus two read-mostly actions:
/// a forced re-detection of the cameras, and a read-only page listing what they
/// were measured to accept. Capture parameters (fps, resolution, quality) are
/// still not editable — they are announced at registration, and a mode change
/// comes from the server through `switch_camera`, which is the only thing that
/// is allowed to move them.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initial,
    required this.onSaved,
    this.isRecording = false,
    this.linkState = LinkState.idle,
    this.probe,
    this.onRefreshCapabilities,
    this.readCapabilities,
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

  /// Runs a **forced** re-probe and applies the result. Null hides the button,
  /// which is what a screen built without a store wants.
  final Future<CameraInventory> Function()? onRefreshCapabilities;

  /// Supplies the per-camera capability report for the read-only capability
  /// page. A callback rather than a list so the page reflects a re-probe that
  /// happened while this screen was open; null hides the entry point.
  final List<CameraCapabilityReport> Function()? readCapabilities;

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
  static const Key refreshCapabilitiesKey = Key(
    'settings-refresh-capabilities',
  );
  static const Key refreshResultKey = Key('settings-refresh-result');
  static const Key viewCapabilitiesKey = Key('settings-view-capabilities');

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

  bool _refreshing = false;
  String? _refreshResult;
  bool _refreshFailed = false;

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

  /// Re-measures every camera and applies the result.
  ///
  /// The outcome is reported here rather than through the status bar because
  /// the probe takes seconds and the screen the operator is looking at is this
  /// one. A failure has to be *said*: the probe swallows its own errors by
  /// design (a rung that will not open contributes nothing), so without this
  /// the only visible result of a device with a broken camera would be a button
  /// that appears to do nothing.
  Future<void> _refreshCapabilities() async {
    final refresh = widget.onRefreshCapabilities;
    if (refresh == null) return;

    setState(() {
      _refreshing = true;
      _refreshResult = null;
      _refreshFailed = false;
    });

    try {
      final inventory = await refresh();
      if (!mounted) return;
      final resolutions = inventory.capabilities.fold<int>(
        0,
        (total, capabilities) => total + capabilities.resolutions.length,
      );
      setState(() {
        _refreshing = false;
        _refreshResult = inventory.isEmpty
            ? '未检测到摄像头。'
            : '检测到 ${inventory.descriptors.length} 个摄像头，'
                  '共 $resolutions 个分辨率。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _refreshFailed = true;
        _refreshResult = '检测失败：$error';
      });
    }
  }

  /// Opens the read-only capability page.
  ///
  /// The report is read **when the button is tapped**, not when this screen was
  /// built: a re-probe can have happened while the operator was sitting here,
  /// and a stale snapshot would contradict the result line right above it.
  Future<void> _openCapabilities() async {
    final read = widget.readCapabilities;
    if (read == null) return;

    final cameras = read();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CapabilitiesScreen(cameras: cameras),
      ),
    );
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
                // Disabled while recording: re-probing reopens every camera,
                // which would kill a live stream — the same hazard the banner
                // above warns about, except this one is preventable.
                if (widget.onRefreshCapabilities != null)
                  OutlinedButton.icon(
                    key: SettingsScreen.refreshCapabilitiesKey,
                    onPressed: (widget.isRecording || _refreshing)
                        ? null
                        : _refreshCapabilities,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(_refreshing ? '检测中…' : '重新检测'),
                  ),
                // Enabled while recording, unlike the button above: this page
                // only reads what was already measured, so it cannot disturb a
                // live stream.
                if (widget.readCapabilities != null)
                  OutlinedButton.icon(
                    key: SettingsScreen.viewCapabilitiesKey,
                    onPressed: _openCapabilities,
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('查看支持的分辨率'),
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

            if (_refreshResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _refreshResult!,
                  key: SettingsScreen.refreshResultKey,
                  style: TextStyle(
                    fontSize: 12,
                    color: _refreshFailed
                        ? const Color(0xFFEF9A9A)
                        : const Color(0xFF81C784),
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
