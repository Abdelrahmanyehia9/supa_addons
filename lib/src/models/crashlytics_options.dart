/// Configuration options for [SupaCrashlyticsService].
final class CrashlyticsOptions {
  const CrashlyticsOptions({
    required this.tableName,
    this.appVersion,
    this.enableInDebug = false,
    this.debug = false,
  });

  /// Supabase table where crash reports are stored.
  final String tableName;

  /// App version attached to every report (e.g. `'1.2.3'`).
  ///
  /// Tip: pass `PackageInfo.fromPlatform().version` here.
  final String? appVersion;

  /// Whether to send crash reports in debug builds.
  ///
  /// Defaults to `false` — crashes are only printed to console in debug mode.
  final bool enableInDebug;

  /// Whether to print service activity to the console.
  final bool debug;
}