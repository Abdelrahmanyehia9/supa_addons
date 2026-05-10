class NotificationOptions {
  final String oneSignalAppId;
  final bool enableLocalNotifications;
  final bool debug;
  const NotificationOptions({
    required this.oneSignalAppId,
    required this.enableLocalNotifications,
    required this.debug,
  });
}
