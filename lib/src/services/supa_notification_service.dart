import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supa_addons/src/models/notification_options.dart';
import 'package:supa_addons/src/helper/local_notification_helper.dart';
import 'package:supa_addons/src/models/supa_notification.dart';

final class SupaNotificationService {

  SupaNotificationService._();
  /// Singleton instance.
  static final SupaNotificationService instance = SupaNotificationService._();

  bool _initialized    = false;
  bool _listenersSetup = false;
  NotificationOptions? _options;

  LocalNotificationService? _localNotificationService;

  // ─── Stream ───────────────────────────────────────────────────────────────

  final StreamController<SupaNotification> _controller =
  StreamController<SupaNotification>.broadcast();
  /// Stream of [SupaNotification] emitted on:
  /// - Push notification clicked (background / killed / foreground)
  /// - Local notification clicked
  Stream<SupaNotification> get stream => _controller.stream;

  // ─── Internal helpers ─────────────────────────────────────────────────────

  NotificationOptions get _safeOptions {
    assert(_options != null, 'Call init() before using SupaNotificationService');
    return _options!;
  }

  void _emit(SupaNotification notification) {
    if (!_controller.isClosed) _controller.add(notification);
  }

  void _log(String message, {bool? isLocal}) {
    if (!_safeOptions.debug) return;
    final tag = isLocal == true ? '📱 LOCAL' : isLocal == false ? '🌐 PUSH' : '🔔 SYSTEM';
    debugPrint('[$tag] $message');
  }

  // ─── Init ─────────────────────────────────────────────────────────────────

  /// Initialises OneSignal and sets up all listeners.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> init({required NotificationOptions options}) async {
    if (_initialized) return;
    _options = options;
    if (_safeOptions.debug) await OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
    await OneSignal.initialize(_safeOptions.oneSignalAppId);
    _initialized = true;
    _log('🚀 SupaNotificationService initialized');
    await _setupListeners();
  }

  // ─── Listeners ────────────────────────────────────────────────────────────

  Future<void> _setupListeners() async {
    if (_listenersSetup) return;
    _listenersSetup = true;
    // Local notifications
    if (_safeOptions.enableLocalNotifications) {
      _localNotificationService = const LocalNotificationService();
      await _localNotificationService!.init(
        onNotificationResponse: (notification) {
          _log('Local notification clicked', isLocal: true);
          _emit(notification);
        },
      );
    }
    // Foreground push: prevent OneSignal default display, show local instead
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      final notification = SupaNotification.fromOSNotification(event.notification);
      _log('Push received (foreground)', isLocal: false);

      if (_safeOptions.enableLocalNotifications) {
        event.preventDefault();
        _localNotificationService?.showNotification(notification);
      }
    });
    OneSignal.Notifications.addClickListener(
            (event) {
      final notification = SupaNotification.fromOSNotification(event.notification);
      _log('Push clicked', isLocal: false);
      _emit(notification);
    }
    );
  }
  // ─── Permissions ──────────────────────────────────────────────────────────
  /// Returns `true` if the user has granted notification permission.
  Future<bool> hasPermission() => Future.value(OneSignal.Notifications.permission);
  /// Prompts the user for notification permission.
  ///
  /// Returns `true` if permission was granted.
  Future<bool> requestPermission() => OneSignal.Notifications.requestPermission(true);
  // ─── User info ────────────────────────────────────────────────────────────
  /// OneSignal subscription ID for this device.
  String? get playerId => OneSignal.User.pushSubscription.id;
  /// Raw FCM / APNs push token.
  String? get pushToken => OneSignal.User.pushSubscription.token;
  // ─── User management ──────────────────────────────────────────────────────
  /// Links this device to an external user ID (e.g. your backend user ID).
  void setExternalUserId(String userId) => OneSignal.login(userId);
  /// Unlinks the external user ID.
  void removeExternalUserId() => OneSignal.logout();
  // ─── Tags ─────────────────────────────────────────────────────────────────
  /// Adds or updates user tags used for segmentation.
  void sendTags(Map<String, dynamic> tags) => OneSignal.User.addTags(tags);
  /// Removes a single tag by [key].
  void removeTag(String key) => OneSignal.User.removeTag(key);
  /// Removes multiple tags by their [keys].
  void removeTags(List<String> keys) => OneSignal.User.removeTags(keys);
  // ─── Subscription ─────────────────────────────────────────────────────────
  /// Opts the user in to push notifications.
  void optIn() => OneSignal.User.pushSubscription.optIn();
  /// Opts the user out of push notifications.
  void optOut() => OneSignal.User.pushSubscription.optOut();
  /// `true` if the user is currently opted in.
  bool get isSubscribed => OneSignal.User.pushSubscription.optedIn ?? false;
  // ─── Reset ────────────────────────────────────────────────────────────────
  /// Logs out the current user and resets initialisation state.
  /// Call on user logout so the next [init] re-attaches a fresh user.
  void reset() {
    removeExternalUserId();
    _initialized = false;
    _listenersSetup = false;
    _options = null;
    _log('🔄 SupaNotificationService reset');
  }
  // ─── Dispose ──────────────────────────────────────────────────────────────
  /// Closes the stream controller. Call when the service is no longer needed.
  void dispose() => _controller.close();

}