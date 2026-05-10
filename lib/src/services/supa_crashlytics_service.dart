import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supa_addons/src/models/crash_report.dart';
import 'package:supa_addons/src/models/crashlytics_options.dart';
import 'package:supa_helper/supa_helper.dart';

 const _kQueueKey          = 'supa_crash_queue';
 const _kMaxQueueSize      = 100;
 const _kMaxStackSize      = 2000;
 const _kMaxCrashPerMinute = 10;
 const _kDedupWindowSize   = 20;
/// ## SupaCrashlyticsService
///
/// Records Flutter & async crashes and persists them to a Supabase table.
///
/// **Protections built-in:**
/// - **Deduplication** — same error within a session is recorded once
/// - **Rate limiting** — max 10 crashes/minute to prevent DB spam
/// - **Recursive crash guard** — upload errors can't trigger new reports
/// - **Flush race condition guard** — concurrent flushes are no-ops
/// - **Offline queue** — failed uploads are retried on next launch (max 100)
/// - **Stack truncation** — stacks capped at 2,000 chars
///
/// ### SQL — create the table
/// ```sql
/// create table app_crashes (
///   id           uuid primary key default gen_random_uuid(),
///   error        text        not null,
///   stack        text        not null,
///   fatal        boolean     not null default false,
///   occurred_at  timestamptz not null,
///   user_id      text,
///   app_version  text,
///   context      jsonb
/// );
/// ```
///
/// ### Setup in `main.dart`
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///
///   await SupaCrashlyticsService.instance.init(
///     options: CrashlyticsOptions(
///       tableName:  'app_crashes',
///       appVersion: '1.0.0',
///     ),
///   );
///
///   FlutterError.onError =
///       SupaCrashlyticsService.instance.onFlutterError;
///
///   runZonedGuarded(
///     () {
///       PlatformDispatcher.instance.onError = (error, stack) {
///         SupaCrashlyticsService.instance.recordError(error, stack, fatal: true);
///         return true;
///       };
///       runApp(const MyApp());
///     },
///     (error, stack) async {
///       await SupaCrashlyticsService.instance.recordError(error, stack, fatal: true);
///     },
///   );
/// }
/// ```
final class SupaCrashlyticsService {
  SupaCrashlyticsService._();

  /// Singleton instance.
  static final SupaCrashlyticsService instance = SupaCrashlyticsService._();

  static bool _initialized = false;
  static late CrashlyticsOptions _options;

  String? _userId;
  SharedPreferences? _prefs;

  // ─── Recursive crash guard ────────────────────────────────────────────────
  // Prevents _upload() errors from triggering new recordError() calls.
  bool _isRecording = false;

  // ─── Flush race condition guard ───────────────────────────────────────────
  bool _isFlushing = false;

  // ─── Deduplication ───────────────────────────────────────────────────────
  // Stores fingerprints of recently seen errors to skip duplicates.
  final _recentFingerprints = <String>[];

  // ─── Rate limiting ────────────────────────────────────────────────────────
  // Tracks timestamps of crashes recorded in the current minute window.
  final _crashTimestamps = <DateTime>[];

  // ─── Init ─────────────────────────────────────────────────────────────────

  /// Initialises the service and flushes any queued offline reports.
  Future<void> init({required CrashlyticsOptions options}) async {
    if (_initialized) return;

    _options     = options;
    _prefs       = await SharedPreferences.getInstance();
    _initialized = true;

    _log('🔥 SupaCrashlyticsService initialized');

    await _flushQueue();
  }

  // ─── Flutter error handler ────────────────────────────────────────────────

  /// Pass this to [FlutterError.onError] in `main.dart`.
  Future<void> onFlutterError(FlutterErrorDetails details) async {
    if (!_shouldRecord) {
      FlutterError.dumpErrorToConsole(details);
      return;
    }

    await recordError(
      details.exception,
      details.stack,
      fatal: true,
      context: {'library': details.library ?? 'unknown'},
    );
  }

  // ─── Record ───────────────────────────────────────────────────────────────

  /// Records a crash or non-fatal error.
  ///
  /// Silently skipped if:
  /// - A duplicate of a recently seen error (deduplication)
  /// - Rate limit exceeded (> 10 crashes/minute)
  /// - Currently inside an upload (recursive crash guard)
  ///
  /// If upload fails, the report is queued offline and retried on next [init].
  Future<void> recordError(
      dynamic error,
      StackTrace? stack, {
        bool fatal = false,
        Map<String, dynamic>? context,
      }) async {
    _ensureInitialized();

    // ── Recursive crash guard ──
    if (_isRecording) {
      _log('⚠️ Recursive crash detected — skipped');
      return;
    }

    // ── Deduplication ──
    final fingerprint = _fingerprint(error, stack);
    if (_recentFingerprints.contains(fingerprint)) {
      _log('⚠️ Duplicate crash — skipped: $fingerprint');
      return;
    }

    // ── Rate limiting ──
    if (_isRateLimited()) {
      _log('⚠️ Rate limit exceeded — crash dropped');
      return;
    }

    final rawStack = stack?.toString() ?? '';

    final report = SupaCrashReport(
      error:      error.toString(),
      stack:      rawStack.substring(0, min(rawStack.length, _kMaxStackSize)),
      fatal:      fatal,
      occurredAt: DateTime.now().toUtc(),
      userId:     _userId,
      appVersion: _options.appVersion,
      context:    context,
    );

    _log('🚨 ${fatal ? "FATAL" : "ERROR"}: ${report.error}');

    // Track fingerprint & timestamp after all guards pass
    _trackFingerprint(fingerprint);
    _trackTimestamp();

    if (!_shouldRecord) return;

    _isRecording = true;
    try {
      final uploaded = await _upload(report);
      if (!uploaded) await _enqueue(report);
    } finally {
      _isRecording = false;
    }
  }

  // ─── Deduplication helpers ────────────────────────────────────────────────

  /// Generates a fingerprint from the error message and stack hash.
  String _fingerprint(dynamic error, StackTrace? stack) =>
      '${error.toString()}_${stack.toString().hashCode}';

  void _trackFingerprint(String fingerprint) {
    // Keep window bounded — drop oldest if full
    if (_recentFingerprints.length >= _kDedupWindowSize) {
      _recentFingerprints.removeAt(0);
    }
    _recentFingerprints.add(fingerprint);
  }

  // ─── Rate limiting helpers ────────────────────────────────────────────────

  /// Returns `true` if more than [_kMaxCrashPerMinute] crashes have been
  /// recorded in the last 60 seconds.
  bool _isRateLimited() {
    final now    = DateTime.now();
    final window = now.subtract(const Duration(minutes: 1));

    // Remove timestamps outside the window
    _crashTimestamps.removeWhere((t) => t.isBefore(window));

    return _crashTimestamps.length >= _kMaxCrashPerMinute;
  }

  void _trackTimestamp() => _crashTimestamps.add(DateTime.now());

  // ─── Upload ───────────────────────────────────────────────────────────────

  Future<bool> _upload(SupaCrashReport report) async {
    try {
      await SupaHelper.instance.database
          .INSERT(table: _options.tableName, data: report.toMap());

      _log('✅ Report uploaded');
      return true;
    } catch (e) {
      _log('⚠️ Upload failed — queuing offline: $e');
      return false;
    }
  }

  // ─── Batch upload ─────────────────────────────────────────────────────────

  /// Uploads multiple reports in a single Supabase insert — used by [_flushQueue].
  Future<bool> _uploadBatch(List<SupaCrashReport> reports) async {
    try {
      await SupaHelper.instance.database.INSERT_MANY(
        table: _options.tableName,
        data:  reports.map((r) => r.toMap()).toList(),
      );

      _log('✅ Batch uploaded ${reports.length} report(s)');
      return true;
    } catch (e) {
      _log('⚠️ Batch upload failed: $e');
      return false;
    }
  }

  // ─── Offline queue ────────────────────────────────────────────────────────

  Future<void> _enqueue(SupaCrashReport report) async {
    try {
      final queue = _readQueue();
      if (queue.length >= _kMaxQueueSize) {
        queue.removeAt(0);
        _log('⚠️ Queue full — oldest report dropped');
      }

      queue.add(jsonEncode(report.toMap()));
      await _prefs!.setStringList(_kQueueKey, queue);
      _log('💾 Report queued (total: ${queue.length})');
    } catch (e) {
      _log('⚠️ Failed to queue report: $e');
    }
  }

  /// Flushes all queued offline reports in a single batch insert.
  ///
  /// Called automatically on [init]. Can also be triggered manually
  /// when connectivity is restored. Concurrent calls are safe — only
  /// one flush runs at a time.
  Future<void> flushQueue() => _flushQueue();

  Future<void> _flushQueue() async {
    // ── Race condition guard ──
    if (_isFlushing) {
      _log('⚠️ Flush already in progress — skipped');
      return;
    }

    final rawQueue = _readQueue();
    if (rawQueue.isEmpty) return;

    _isFlushing = true;
    _log('📤 Flushing ${rawQueue.length} queued report(s)');

    try {
      final reports = <SupaCrashReport>[];
      for (final raw in rawQueue) {
        try {
          reports.add(
            SupaCrashReport.fromMap(jsonDecode(raw) as Map<String, dynamic>),
          );
        } catch (e) {
          _log('⚠️ Skipped malformed queued report: $e');
        }
      }

      if (reports.isEmpty) {
        await _prefs!.remove(_kQueueKey);
        return;
      }

      final uploaded = await _uploadBatch(reports);

      if (uploaded) {
        await _prefs!.remove(_kQueueKey);
        _log('📤 Flush done — ${reports.length} uploaded');
      } else {
        _log('📤 Flush failed — ${reports.length} reports still pending');
      }
    } finally {
      _isFlushing = false;
    }
  }

  List<String> _readQueue() =>
      _prefs?.getStringList(_kQueueKey) ?? [];

  // ─── User identity ────────────────────────────────────────────────────────

  /// Attaches a user ID to all subsequent crash reports. Call after login.
  void setUserId(String userId) {
    _ensureInitialized();
    _userId = userId;
    _log('👤 User ID set: $userId');
  }

  /// Clears the attached user ID — call on logout.
  void clearUser() {
    _userId = null;
    _log('👤 User ID cleared');
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'SupaCrashlyticsService is not initialized. Call init() first.',
      );
    }
  }

  bool get _shouldRecord => kReleaseMode || _options.enableInDebug;

  void _log(String message) {
    if (_options.debug) debugPrint('[🔥 Crashlytics] $message');
  }
}