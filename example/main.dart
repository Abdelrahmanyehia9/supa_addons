import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supa_addons/supa_addons.dart';

// ─── 1. Init all services before runApp ───────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Crashlytics ──────────────────────────────────────────────────────────
  await SupaCrashlyticsService.instance.init(
     options: const CrashlyticsOptions(
      tableName:    'app_crashes',
      appVersion:   '1.0.0',
      enableInDebug: false,
      debug:         true,
    ),
  );

  FlutterError.onError = SupaCrashlyticsService.instance.onFlutterError;

  // ── Notifications ────────────────────────────────────────────────────────
  await SupaNotificationService.instance.init(
    options: const NotificationOptions(
      oneSignalAppId:           'YOUR_ONESIGNAL_APP_ID',
      enableLocalNotifications:  true,
      debug:                     true,
    ),
  );

  // ── Remote Config ────────────────────────────────────────────────────────
  final  config = SupaRemoteConfig(
    const RemoteConfigOption(
      tableName: '_config',
      debug:     true,
    ),
  );

  await config.init(defaultValues: {
    'maintenance_mode': false,
    'min_version':      '1.0.0',
    'max_retries':      3,
    'welcome_message':  'Hello!',
    'feature_flags':    <String>[],
  });

  runZonedGuarded(
        () {
      PlatformDispatcher.instance.onError = (error, stack) {
        SupaCrashlyticsService.instance.recordError(error, stack, fatal: true);
        return true;
      };
      runApp(MyApp(config: config));
    },
        (error, stack) async {
      await SupaCrashlyticsService.instance.recordError(
        error,
        stack,
        fatal: true,
      );
    },
  );
}

// ─── 2. App root ──────────────────────────────────────────────────────────────

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.config});
  final SupaRemoteConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'supa_addons example',
      home: HomeScreen(config: config),
    );
  }
}

// ─── 3. Home screen — all three services in action ────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.config});
  final SupaRemoteConfig config;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _lastNotification = '—';
  String _lastError        = '—';

  // ── Notification stream ──────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    SupaNotificationService.instance.stream.listen((notification) {
      setState(() {
        _lastNotification =
        '${notification.title ?? "no title"} — ${notification.body ?? "no body"}';
      });

      // Navigate based on data payload
      final screen = notification.data?['screen'] as String?;
      if (screen != null) {
        debugPrint('Navigate to: $screen');
      }
    });
  }

  // ── Simulate a non-fatal error ───────────────────────────────────────────
  Future<void> _simulateError() async {
    try {
      throw Exception('Simulated network timeout');
    } catch (e, stack) {
      await SupaCrashlyticsService.instance.recordError(
        e,
        stack,
        context: {'screen': 'HomeScreen', 'action': 'load_feed'},
      );
      setState(() => _lastError = e.toString());
    }
  }

  // ── Simulate login / logout ──────────────────────────────────────────────
  void _onLogin() {
    const userId = 'user-123';

    // attach user to crash reports
    SupaCrashlyticsService.instance.setUserId(userId);

    // link device to OneSignal user
    SupaNotificationService.instance.setExternalUserId(userId);

    // tag for segmentation
    SupaNotificationService.instance.sendTags({'plan': 'pro', 'country': 'eg'});

    debugPrint('Logged in as $userId');
  }

  void _onLogout() {
    SupaCrashlyticsService.instance.clearUser();
    SupaNotificationService.instance.reset();
    debugPrint('Logged out');
  }

  // ── Request notification permission ─────────────────────────────────────
  Future<void> _requestPermission() async {
    final granted =
    await SupaNotificationService.instance.requestPermission();
    debugPrint('Permission granted: $granted');
  }

  // ── Force remote config refresh ──────────────────────────────────────────
  Future<void> _forceRefresh() async {
    await widget.config.forceRefresh();
    setState(() {}); // rebuild to show fresh values
  }

  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // ── Remote config values ─────────────────────────────────────────────
    final maintenance = widget.config.getBool('maintenance_mode');
    final minVersion  = widget.config.getString('min_version');
    final maxRetries  = widget.config.getInt('max_retries');
    final welcome     = widget.config.getString('welcome_message');
    final flags       = widget.config.getList<String>('feature_flags');

    if (maintenance) {
      return const Scaffold(
        body: Center(child: Text('🚧 App is under maintenance')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('supa_addons example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Remote Config ──────────────────────────────────────────────
          _Section(
            title: '⚙️ Remote Config',
            children: [
              _Row('welcome_message', welcome),
              _Row('min_version',     minVersion),
              _Row('max_retries',     maxRetries.toString()),
              _Row('feature_flags',   flags.join(', ')),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _forceRefresh,
                child: const Text('Force Refresh'),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Notifications ──────────────────────────────────────────────
          _Section(
            title: '🔔 Notifications',
            children: [
              _Row('Last notification', _lastNotification),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: _requestPermission,
                    child: const Text('Request Permission'),
                  ),
                  ElevatedButton(
                    onPressed: () =>
                        SupaNotificationService.instance.optIn(),
                    child: const Text('Opt In'),
                  ),
                  ElevatedButton(
                    onPressed: () =>
                        SupaNotificationService.instance.optOut(),
                    child: const Text('Opt Out'),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Crashlytics ────────────────────────────────────────────────
          _Section(
            title: '🔥 Crashlytics',
            children: [
              _Row('Last recorded error', _lastError),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _simulateError,
                child: const Text('Simulate Non-Fatal Error'),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Auth simulation ────────────────────────────────────────────
          _Section(
            title: '👤 User',
            children: [
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: _onLogin,
                    child: const Text('Login'),
                  ),
                  ElevatedButton(
                    onPressed: _onLogout,
                    child: const Text('Logout'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Small helper widgets ─────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String       title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Expanded(
            child: Text(value,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.black54)),
          ),
        ],
      ),
    );
  }
}