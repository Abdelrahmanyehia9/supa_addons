# supa_addons

A Flutter package that extends [Supabase](https://supabase.com/) with three production-ready services: **crash reporting**, **push notifications**, and **remote config** — all wired to your Supabase project out of the box.

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Services](#services)
    - [SupaCrashlyticsService](#supacrashlyticsservice)
    - [SupaNotificationService](#supanotificationservice)
    - [SupaRemoteConfig](#suparemoteconfig)
- [Models](#models)
- [FAQ](#faq)

---

## Features

| Service | What it does |
|---|---|
| `SupaCrashlyticsService` | Captures Flutter & async crashes → uploads to Supabase with dedup, rate-limit, offline queue, and retry |
| `SupaNotificationService` | Wraps OneSignal push + `flutter_local_notifications` in a single unified stream |
| `SupaRemoteConfig` | TTL-cached key-value config from a Supabase table with typed getters |

---

## Installation

Add to `pubspec.yaml`:

```yaml
dependencies:
  supa_addons: ^1.0.0
```

Then run:

```bash
flutter pub get
```

---

## Services

---

### SupaCrashlyticsService

Records every Flutter and async crash and persists it to a Supabase table. Built-in protections prevent runaway DB writes.

#### Built-in protections

| Protection | Detail |
|---|---|
| Deduplication | Same error fingerprint within a session is recorded only once |
| Rate limiting | Max **10 crashes / minute** — excess are silently dropped |
| Recursive crash guard | Upload errors cannot trigger new `recordError()` calls |
| Flush race guard | Concurrent `flushQueue()` calls are no-ops |
| Offline queue | Failed uploads are persisted in `SharedPreferences` and retried with up to **3 attempts** (5 s delay between each) on next launch |
| Stack truncation | Stacks are capped at **2,000 characters** to keep DB rows lean |

#### Supabase table

```sql
create table app_crashes (
  id           uuid primary key default gen_random_uuid(),
  error        text        not null,
  stack        text        not null,
  fatal        boolean     not null default false,
  occurred_at  timestamptz not null,
  user_id      text,
  app_version  text,
  context      jsonb
);
```

#### Setup

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SupaCrashlyticsService.instance.init(
    options: CrashlyticsOptions(
      tableName:  'app_crashes',
      appVersion: '1.0.0',       // tip: use PackageInfo.fromPlatform().version
      enableInDebug: false,       // set true to also log in debug builds
      debug: false,               // set true to print service activity
    ),
  );

  // Catch Flutter framework errors
  FlutterError.onError = SupaCrashlyticsService.instance.onFlutterError;

  runZonedGuarded(
    () {
      // Catch platform-level errors
      PlatformDispatcher.instance.onError = (error, stack) {
        SupaCrashlyticsService.instance.recordError(error, stack, fatal: true);
        return true;
      };
      runApp(const MyApp());
    },
    // Catch all other async errors
    (error, stack) async {
      await SupaCrashlyticsService.instance.recordError(error, stack, fatal: true);
    },
  );
}
```

#### Recording errors manually

```dart
// Non-fatal — e.g. a caught network exception
try {
  await someApiCall();
} catch (e, stack) {
  await SupaCrashlyticsService.instance.recordError(
    e,
    stack,
    fatal: false,
    context: {'screen': 'HomeScreen', 'action': 'load_feed'},
  );
}

// Fatal — app cannot continue
await SupaCrashlyticsService.instance.recordError(e, stack, fatal: true);
```

#### User identity

```dart
// After login — attaches user ID to every subsequent report
SupaCrashlyticsService.instance.setUserId(user.id);

// After logout — detaches user ID
SupaCrashlyticsService.instance.clearUser();
```

#### Manual flush (e.g. on connectivity restored)

```dart
await SupaCrashlyticsService.instance.flushQueue();
```

#### Options reference — `CrashlyticsOptions`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `tableName` | `String` | required | Supabase table name |
| `appVersion` | `String?` | `null` | App version string attached to every report |
| `enableInDebug` | `bool` | `false` | Send reports even in debug builds |
| `debug` | `bool` | `false` | Print service activity to console |

---

### SupaNotificationService

Wraps [OneSignal](https://onesignal.com/) push notifications and `flutter_local_notifications` in a single unified `Stream<SupaNotification>` — no callbacks, no spaghetti.

#### How it works

```
OneSignal push received (foreground)
        │
        ▼
  preventDefault() ──► LocalNotificationService.showNotification()
                                    │
                          user taps notification
                                    │
                                    ▼
                          stream.add(SupaNotification)

OneSignal push clicked (background / killed)
        │
        ▼
  stream.add(SupaNotification)
```

#### Setup

```dart
await SupaNotificationService.instance.init(
  options: NotificationOptions(
    oneSignalAppId: 'YOUR_ONESIGNAL_APP_ID',
    enableLocalNotifications: true,   // show heads-up banners in foreground
    debug: false,
  ),
);
```

#### Listening to notifications

```dart
SupaNotificationService.instance.stream.listen((notification) {
  print('Tapped: ${notification.title}');
  print('Data:   ${notification.data}');

  // Navigate based on payload
  final screen = notification.data?['screen'] as String?;
  if (screen != null) router.go(screen);
});
```

#### Permissions

```dart
// Check current permission status
final granted = await SupaNotificationService.instance.hasPermission();

// Request permission (shows native dialog)
final granted = await SupaNotificationService.instance.requestPermission();
```

#### User management

```dart
// Link device to your backend user (call after login)
SupaNotificationService.instance.setExternalUserId(user.id);

// Unlink on logout
SupaNotificationService.instance.removeExternalUserId();
```

#### Tags (for segmentation)

```dart
// Add / update tags
SupaNotificationService.instance.sendTags({'plan': 'pro', 'country': 'eg'});

// Remove a single tag
SupaNotificationService.instance.removeTag('plan');

// Remove multiple tags
SupaNotificationService.instance.removeTags(['plan', 'country']);
```

#### Subscription control

```dart
SupaNotificationService.instance.optIn();   // subscribe
SupaNotificationService.instance.optOut();  // unsubscribe

bool subscribed = SupaNotificationService.instance.isSubscribed;

// Device identifiers
String? playerId  = SupaNotificationService.instance.playerId;
String? pushToken = SupaNotificationService.instance.pushToken;
```

#### Lifecycle

```dart
// On user logout — resets state so the next init() re-attaches a fresh user
SupaNotificationService.instance.reset();

// When the service is permanently torn down
SupaNotificationService.instance.dispose();
```

#### Options reference — `NotificationOptions`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `oneSignalAppId` | `String` | ✅ | Your OneSignal application ID |
| `enableLocalNotifications` | `bool` | ✅ | Show heads-up banners while app is in foreground |
| `debug` | `bool` | ✅ | Print tagged log lines to console |

---

### SupaRemoteConfig

Fetches key-value config from a Supabase table with **TTL-based caching**. The app never blocks on network — it always resolves from cache or defaults.

#### Priority chain

```
1. Remote (Supabase)        ← only when TTL has expired
       │
       ▼
2. Local cache (SharedPreferences)  ← used while cache is still fresh
       │
       ▼
3. Default values           ← always the base layer
```

#### Supabase table

```sql
create table remote_config (
  key   text primary key,
  value text not null   -- stored as JSON-encoded string
);

-- Examples
insert into remote_config values
  ('maintenance_mode', 'false'),
  ('min_version',      '"1.2.0"'),
  ('max_retries',      '3'),
  ('feature_flags',    '["dark_mode","new_checkout"]');
```

#### Setup

```dart
final config = SupaRemoteConfig(
  RemoteConfigOption(
    tableName: 'remote_config',
    ttl:       const Duration(hours: 1),
    debug:     false,
  ),
);

await config.init(defaultValues: {
  'maintenance_mode': false,
  'min_version':      '1.0.0',
  'max_retries':      3,
  'feature_flags':    <String>[],
});
```

#### Typed getters

```dart
final maintenance = config.getBool('maintenance_mode');           // false
final version     = config.getString('min_version');              // '1.2.0'
final retries     = config.getInt('max_retries');                 // 3
final ratio       = config.getDouble('discount_ratio', fallback: 0.1);
final flags       = config.getList<String>('feature_flags');      // ['dark_mode', ...]
final theme       = config.getMap('theme_config');                // {'primary': '#FF0000'}
final raw         = config.get('anything');                       // dynamic

bool exists = config.containsKey('maintenance_mode');
Map<String, dynamic> snapshot = config.all;                       // full in-memory cache
```

#### Cache control

```dart
// Force a remote fetch right now, ignoring TTL
// Useful after login or pull-to-refresh
await config.forceRefresh();

// Wipe local cache — next init() will always hit remote
await config.clearCache();
```

#### Options reference — `RemoteConfigOption`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `tableName` | `String` | required | Supabase table name |
| `ttl` | `Duration` | `Duration(hours: 1)` | How long the local cache stays fresh |
| `debug` | `bool` | `false` | Print cache/fetch activity to console |

---

## Models

### `SupaNotification`

Unified notification model produced by both OneSignal and `flutter_local_notifications`.

| Field | Type | Description |
|---|---|---|
| `id` | `String` | Notification ID |
| `title` | `String?` | Notification title |
| `body` | `String?` | Notification body / payload string |
| `data` | `Map<String, dynamic>?` | Parsed JSON data from the notification |
| `image` | `String?` | Big picture URL (OneSignal only) |

### `SupaCrashReport`

Represents a single crash entry. Serialised to/from the `app_crashes` table.

| Field | Type | Description |
|---|---|---|
| `error` | `String` | Error message |
| `stack` | `String` | Stack trace (truncated to 2,000 chars) |
| `fatal` | `bool` | Whether the error was fatal |
| `occurredAt` | `DateTime` | UTC timestamp |
| `userId` | `String?` | Attached user ID at the time of crash |
| `appVersion` | `String?` | App version string |
| `context` | `Map<String, dynamic>?` | Free-form metadata (e.g. current screen) |

---

## FAQ

**Does `SupaCrashlyticsService` send reports in debug mode?**
No — by default it only records in release mode. Set `enableInDebug: true` in `CrashlyticsOptions` to also capture in debug builds.

**What happens if Supabase is unreachable?**
The crash report is serialised to `SharedPreferences` and retried on the next app launch (up to 3 attempts, 5 seconds apart). The queue holds up to 100 reports — oldest are dropped when the limit is exceeded.

**Can I use `SupaNotificationService` without local notifications?**
Yes — set `enableLocalNotifications: false`. OneSignal will handle display on its own and the `stream` will still emit on click.

**How do I force `SupaRemoteConfig` to always fetch fresh?**
Call `await config.clearCache()` before `init()`, or call `await config.forceRefresh()` at any point after.

**Is `SupaRemoteConfig` safe to use if the network is down?**
Yes — `init()` never throws. If remote fetch fails, it silently falls back to the local cache and then to the default values you provided.