class RemoteConfigOption {
  final String   tableName;
  final Duration ttl;
  final bool   debug;
  const RemoteConfigOption({
    required this.tableName,
    this.ttl   = const Duration(hours: 1),
    this.debug = false,
  });
}