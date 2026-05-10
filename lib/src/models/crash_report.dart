
/// Represents a single crash report entry.
final class SupaCrashReport {
  const SupaCrashReport({
    required this.error,
    required this.stack,
    required this.fatal,
    required this.occurredAt,
    this.userId,
    this.appVersion,
    this.context,
  });

  final String error;
  final String stack;
  final bool fatal;
  final DateTime occurredAt;
  final String? userId;
  final String? appVersion;

  /// Optional free-form context (e.g. current screen, extra metadata).
  final Map<String, dynamic>? context;

  Map<String, dynamic> toMap() => {
    'error':       error,
    'stack':       stack,
    'fatal':       fatal,
    'occurred_at': occurredAt.toIso8601String(),
    if (userId     != null) 'user_id':     userId,
    if (appVersion != null) 'app_version': appVersion,
    if (context    != null) 'context':     context,
  };

  factory SupaCrashReport.fromMap(Map<String, dynamic> map) => SupaCrashReport(
    error:      map['error']  as String,
    stack:      map['stack']  as String,
    fatal:      map['fatal']  as bool,
    occurredAt: DateTime.parse(map['occurred_at'] as String),
    userId:     map['user_id']     as String?,
    appVersion: map['app_version'] as String?,
    context:    map['context']     as Map<String, dynamic>?,
  );

  @override
  String toString() => '[${fatal ? "FATAL" : "ERROR"}] $error\n$stack';
}