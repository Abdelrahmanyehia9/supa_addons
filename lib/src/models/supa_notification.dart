import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

class SupaNotification {
  final String? title ;
  final String id;
  final String? body;
  final Map<String, dynamic>? data;
  final String? image;

 const SupaNotification({
    required this.id,
    this.title,
     this.body,
     this.data,
     this.image,
  });


 factory SupaNotification.fromOSNotification(OSNotification os)=>SupaNotification(
     id: os.notificationId,
     body: os.body,
     data: os.additionalData,
     title: os.title??"",
     image: os.bigPicture) ;
 factory SupaNotification.fromFLNotification(NotificationResponse lN)=>SupaNotification(
     id: lN.id.toString(),
     body: lN.payload,
     data: lN.data,
     ) ;
}
