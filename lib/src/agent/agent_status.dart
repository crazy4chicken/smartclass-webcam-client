import '../backend/backend_gateway.dart';

/// Everything the status bar needs, as a single immutable snapshot.
class AgentStatus {
  const AgentStatus({
    required this.connection,
    required this.fps,
    required this.cameraName,
    required this.streaming,
    required this.autonomous,
    required this.resolutionLabel,
    required this.streamModeLabel,
    required this.previewEnabled,
    required this.backendId,
  });

  final ConnectionState connection;
  final double fps;
  final String cameraName;
  final bool streaming;

  /// True when no backend command arrived in time and we are running on local
  /// defaults while retrying registration.
  final bool autonomous;

  final String resolutionLabel;
  final String streamModeLabel;

  /// Preview can be off while [streaming] stays true — those are independent.
  final bool previewEnabled;

  final String backendId;

  bool get isConnected => connection == ConnectionState.connected;

  bool get isReconnecting => connection == ConnectionState.reconnecting;

  static const AgentStatus initial = AgentStatus(
    connection: ConnectionState.offline,
    fps: 0,
    cameraName: '',
    streaming: false,
    autonomous: false,
    resolutionLabel: '-',
    streamModeLabel: '-',
    previewEnabled: true,
    backendId: '',
  );
}
