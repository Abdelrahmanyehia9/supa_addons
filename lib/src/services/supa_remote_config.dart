import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supa_addons/src/models/remote_config_option.dart';
import 'package:supa_helper/supa_helper.dart';


const _kCacheDataKey      = 'supa_remote_config_data';
const _kCacheTimestampKey = 'supa_remote_config_ts';


/// ## SupaRemoteConfig
///
/// Fetches key-value config from a Supabase table with TTL-based caching.
///
/// **Priority chain (highest → lowest):**
/// 1. Remote (Supabase) — only when TTL has expired
/// 2. Local cache (SharedPreferences) — used when cache is still fresh
/// 3. Default values — always the base layer
///
/// **TTL behaviour:**
/// - Cache is considered fresh while `now < lastFetchedAt + ttl`
/// - On expiry, remote is fetched and cache is refreshed
/// - If remote fails, stale cache is kept silently
///
/// ### Usage
/// ```dart
/// final config = SupaRemoteConfig(
///   RemoteConfigOption(
///     tableName: 'remote_config',
///     ttl: Duration(hours: 1),
///   ),
/// );
///
/// await config.init(defaultValues: {
///   'maintenance_mode': false,
///   'min_version': '1.0.0',
///   'max_retries': 3,
/// });
///
/// final maintenance = config.getBool('maintenance_mode');
/// final version     = config.getString('min_version');
/// final retries     = config.getInt('max_retries');
/// ```
///
/// ### Expected Supabase table schema
/// ```sql
/// create table remote_config (
///   key   text primary key,
///   value text not null   -- stored as JSON-encoded string
/// );
///
/// -- Examples
/// insert into remote_config values
///   ('maintenance_mode', 'false'),
///   ('min_version',      '"1.0.0"'),
///   ('max_retries',      '3');
/// ```
final class SupaRemoteConfig {
  SupaRemoteConfig(this._options);

  final RemoteConfigOption _options;

  // In-memory cache — merged result of defaults + prefs + remote
  Map<String, dynamic> _cache = {};

  // Cached SharedPreferences instance — avoids repeated async getInstance()
  SharedPreferences? _prefs;

  // ─── Init ─────────────────────────────────────────────────────────────────

  /// Loads config using the TTL strategy.
  ///
  /// - If cache is **fresh** → loads from [SharedPreferences] only
  /// - If cache is **expired / missing** → fetches from Supabase and persists
  ///
  /// Always resolves — never throws, so the app never crashes on config errors.
  Future<void> init({required Map<String, dynamic> defaultValues}) async {
    _prefs = await SharedPreferences.getInstance();
    _cache = Map.of(defaultValues);

    if (await _isCacheFresh()) {
      await _loadFromPrefs();
      _log('⚡ Cache fresh — skipped remote fetch');
    } else {
      await _loadFromPrefs();
      await _fetchFromRemote();
    }

    _log('✅ Config ready — ${_cache.length} keys loaded');
  }

  // ─── TTL ──────────────────────────────────────────────────────────────────

  /// Returns `true` if the last fetch is still within the TTL window.
  Future<bool> _isCacheFresh() async {
    try {
      final ts = _prefs!.getInt(_kCacheTimestampKey);
      if (ts == null) return false;

      final age     = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
      final isFresh = age < _options.ttl;

      _log('🕐 Cache age: ${age.inMinutes}m | TTL: ${_options.ttl.inMinutes}m | ${isFresh ? "FRESH" : "EXPIRED"}');

      return isFresh;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveTimestamp() async {
    await _prefs!.setInt(_kCacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  // ─── Remote fetch ─────────────────────────────────────────────────────────

  Future<void> _fetchFromRemote() async {
    try {
      final rows = await SupaHelper.instance.database
          .GET(table: _options.tableName, select: 'key,value');

      if (rows.isEmpty) return;

      final remoteMap = <String, dynamic>{
        for (final row in rows)
          row['key'] as String: _parseValue(row['value'] as String),
      };

      _cache.addAll(remoteMap);
      await _saveToPrefs(remoteMap);
      await _saveTimestamp();

      _log('🌐 Fetched ${remoteMap.length} keys from remote');
    } catch (e) {
      _log('⚠️ Remote fetch failed — using cached/default values: $e');
    }
  }

  // ─── SharedPreferences ────────────────────────────────────────────────────

  Future<void> _loadFromPrefs() async {
    try {
      final raw = _prefs!.getString(_kCacheDataKey);
      if (raw == null) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final saved = decoded.cast<String, dynamic>();
      _cache.addAll(saved);

      _log('💾 Loaded ${saved.length} keys from local cache');
    } catch (e) {
      _log('⚠️ Failed to load local cache: $e');
    }
  }

  Future<void> _saveToPrefs(Map<String, dynamic> data) async {
    try {
      await _prefs!.setString(_kCacheDataKey, jsonEncode(data));
    } catch (e) {
      _log('⚠️ Failed to persist cache: $e');
    }
  }

  // ─── Public cache control ─────────────────────────────────────────────────

  /// Clears the persisted cache and TTL timestamp.
  ///
  /// The next [init] call will force a remote fetch.
  Future<void> clearCache() async {
    await _prefs?.remove(_kCacheDataKey);
    await _prefs?.remove(_kCacheTimestampKey);
    _log('🗑️ Cache cleared');
  }

  /// Forces a remote fetch immediately, ignoring the current TTL.
  ///
  /// Useful for pull-to-refresh or post-login scenarios.
  Future<void> forceRefresh() async {
    _log('🔄 Force refresh triggered');
    await _fetchFromRemote();
  }

  // ─── Typed getters ────────────────────────────────────────────────────────

  /// Returns the raw value for [key], or `null` if not found.
  dynamic get(String key) => _cache[key];

  /// Returns a [String] value.
  ///
  /// Accepts any value and calls `.toString()` on it, so numbers stored
  /// remotely as `42` will return `"42"` instead of the [fallback].
  String getString(String key, {String fallback = ''}) {
    final v = _cache[key];
    if (v == null) return fallback;
    return v is String ? v : v.toString();
  }

  /// Returns a [bool] value.
  ///
  /// Also coerces the string `"true"` / `"false"` for robustness.
  bool getBool(String key, {bool fallback = false}) {
    final v = _cache[key];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return fallback;
  }

  /// Returns an [int] value.
  ///
  /// Also parses numeric strings (e.g. `"42"`).
  int getInt(String key, {int fallback = 0}) {
    final v = _cache[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }
  /// Returns a [double] value.
  ///
  /// Also parses numeric strings (e.g. `"3.14"`).
  double getDouble(String key, {double fallback = 0.0}) {
    final v = _cache[key];
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  /// Returns a [List] value.
  ///
  /// Returns [fallback] if the key is missing, not a List, or the cast fails.
  List<T> getList<T>(String key, {List<T> fallback = const []}) {
    final v = _cache[key];
    if (v is! List) return fallback;
    try {
      return v.cast<T>();
    } catch (_) {
      _log('⚠️ getList<$T>("$key"): cast failed — returning fallback');
      return fallback;
    }
  }

  /// Returns a [Map] value.
  ///
  /// Returns [fallback] if the key is missing, not a Map, or the cast fails.
  Map<String, dynamic> getMap(String key, {Map<String, dynamic> fallback = const {}}) {
    final v = _cache[key];
    if (v is! Map) return fallback;
    try {
      return v.cast<String, dynamic>();
    } catch (_) {
      _log('⚠️ getMap("$key"): cast failed — returning fallback');
      return fallback;
    }
  }

  /// Returns `true` if [key] exists in the loaded config.
  bool containsKey(String key) => _cache.containsKey(key);

  /// Full snapshot of the current in-memory config (read-only).
  Map<String,dynamic> get all => Map.unmodifiable(_cache);

  // ─── Helpers ──────────────────────────────────────────────────────────────

  /// Decodes a JSON-encoded string into its native Dart type.
  ///
  /// Falls back to returning [raw] as a plain string if decoding fails,
  /// so plain text values in the table still work without JSON encoding.
  dynamic _parseValue(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  void _log(String message) {
    if (_options.debug) debugPrint('[⚙️ RemoteConfig] $message');
  }
}