import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Service to manage user notifications with FIFO circular buffer (max 10)
class UserNotificationService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const int MAX_NOTIFICATIONS = 10;

  /// Notification types
  static const String TYPE_PICKUP_SCHEDULED = 'pickup_scheduled';
  static const String TYPE_COLLECTOR_NEARBY = 'collector_nearby';
  static const String TYPE_BIN_COLLECTED = 'bin_collected';
  static const String TYPE_BIN_MISSED = 'bin_missed';
  static const String TYPE_COLLECTOR_PASSED = 'collector_passed';
  static const String TYPE_GARBAGE_ADDED = 'garbage_added';
  static const String TYPE_SESSION_FINISHED = 'session_finished';

  /// Add a notification to user's recent activity
  Future<void> addNotification({
    required String userId,
    required String type,
    required String message,
    String? relatedBinId,
    String? relatedRouteId,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // Create notification document
      await _firestore.collection('user_notifications').add({
        'userId': userId,
        'type': type,
        'message': message,
        'relatedBinId': relatedBinId,
        'relatedRouteId': relatedRouteId,
        'metadata': metadata ?? {},
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      });

      // Cleanup old notifications (keep only 10 most recent)
      await _cleanupOldNotifications(userId);
    } catch (e) {
      print('Error adding notification: $e');
    }
  }

  /// Get user's recent notifications (max 10, FIFO)
  Stream<QuerySnapshot> getUserNotifications() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Stream.empty();

    return _firestore
        .collection('user_notifications')
        .where('userId', isEqualTo: user.uid)
        .orderBy('timestamp', descending: true)
        .limit(MAX_NOTIFICATIONS)
        .snapshots();
  }

  /// Mark notification as read
  Future<void> markAsRead(String notificationId) async {
    try {
      await _firestore
          .collection('user_notifications')
          .doc(notificationId)
          .update({
        'isRead': true,
      });
    } catch (e) {
      print('Error marking notification as read: $e');
    }
  }

  /// Mark all notifications as read
  Future<void> markAllAsRead() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final notifications = await _firestore
          .collection('user_notifications')
          .where('userId', isEqualTo: user.uid)
          .where('isRead', isEqualTo: false)
          .get();

      for (var doc in notifications.docs) {
        await doc.reference.update({'isRead': true});
      }
    } catch (e) {
      print('Error marking all as read: $e');
    }
  }

  /// Cleanup old notifications (FIFO - keep only 10 most recent)
  Future<void> _cleanupOldNotifications(String userId) async {
    try {
      // Get all notifications for user, ordered by timestamp
      final notifications = await _firestore
          .collection('user_notifications')
          .where('userId', isEqualTo: userId)
          .orderBy('timestamp', descending: true)
          .get();

      // If more than MAX_NOTIFICATIONS, delete the oldest ones
      if (notifications.docs.length > MAX_NOTIFICATIONS) {
        final toDelete = notifications.docs.skip(MAX_NOTIFICATIONS).toList();

        for (var doc in toDelete) {
          await doc.reference.delete();
        }

        print(
            '🗑️ Deleted ${toDelete.length} old notifications for user $userId');
      }
    } catch (e) {
      print('Error cleaning up notifications: $e');
    }
  }

  /// Delete notifications older than 30 days (for all users)
  static Future<void> cleanupExpiredNotifications() async {
    try {
      final firestore = FirebaseFirestore.instance;
      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));

      final oldNotifications = await firestore
          .collection('user_notifications')
          .where('timestamp', isLessThan: Timestamp.fromDate(thirtyDaysAgo))
          .get();

      for (var doc in oldNotifications.docs) {
        await doc.reference.delete();
      }

      print(
          '🗑️ Cleaned up ${oldNotifications.docs.length} expired notifications');
    } catch (e) {
      print('Error cleaning up expired notifications: $e');
    }
  }

  /// Notify users when collector starts session on their route
  static Future<void> notifyCollectorStarted({
    required String routeId,
    required String routeName,
    required String collectorId,
  }) async {
    try {
      final firestore = FirebaseFirestore.instance;

      // Find all users who have pinned bins on this route
      final route =
          await firestore.collection('collector_routes').doc(routeId).get();
      if (!route.exists) return;

      // Get all pending bins along the route
      final bins = await firestore
          .collection('garbage_reports')
          .where('status', isEqualTo: 'pending')
          .get();

      // TODO: Filter bins by route proximity (using route points)
      // For now, notify all users with pending bins
      final notifiedUsers = <String>{};

      for (var bin in bins.docs) {
        final binData = bin.data();
        final userId = binData['reportedBy'] as String?;

        if (userId != null && !notifiedUsers.contains(userId)) {
          await UserNotificationService().addNotification(
            userId: userId,
            type: TYPE_COLLECTOR_NEARBY,
            message:
                'Garbage collector has started collecting on route: $routeName',
            relatedRouteId: routeId,
          );
          notifiedUsers.add(userId);
        }
      }

      print(
          '✅ Notified ${notifiedUsers.length} users about collector starting');
    } catch (e) {
      print('Error notifying users about collector start: $e');
    }
  }

  /// Notify users when collector finishes session
  static Future<void> notifyCollectorFinished({
    required String routeId,
    required String routeName,
    required List<String> collectedBinIds,
    required List<String> missedBinIds,
  }) async {
    try {
      final firestore = FirebaseFirestore.instance;

      // Notify users whose bins were collected
      for (var binId in collectedBinIds) {
        final bin =
            await firestore.collection('garbage_reports').doc(binId).get();
        if (bin.exists) {
          final userId = bin.data()?['reportedBy'] as String?;
          if (userId != null) {
            await UserNotificationService().addNotification(
              userId: userId,
              type: TYPE_BIN_COLLECTED,
              message: 'Your trash bin has been collected!',
              relatedBinId: binId,
              relatedRouteId: routeId,
            );
          }
        }
      }

      // Notify users whose bins were missed
      for (var binId in missedBinIds) {
        final bin =
            await firestore.collection('garbage_reports').doc(binId).get();
        if (bin.exists) {
          final userId = bin.data()?['reportedBy'] as String?;
          if (userId != null) {
            await UserNotificationService().addNotification(
              userId: userId,
              type: TYPE_BIN_MISSED,
              message:
                  'Your bin was missed. Please create another pin on the next pickup schedule before the collector passes your location.',
              relatedBinId: binId,
              relatedRouteId: routeId,
            );
          }
        }
      }

      // Notify all users on the route that collector finished
      final allUsers = <String>{};

      // Collect all user IDs from collected and missed bins
      for (var binId in collectedBinIds) {
        final bin =
            await firestore.collection('garbage_reports').doc(binId).get();
        final userId = bin.data()?['reportedBy'] as String?;
        if (userId != null) allUsers.add(userId);
      }

      for (var binId in missedBinIds) {
        final bin =
            await firestore.collection('garbage_reports').doc(binId).get();
        final userId = bin.data()?['reportedBy'] as String?;
        if (userId != null) allUsers.add(userId);
      }

      // Send session finished notification to all affected users
      for (var userId in allUsers) {
        await UserNotificationService().addNotification(
          userId: userId,
          type: TYPE_SESSION_FINISHED,
          message:
              'Garbage collector has finished collecting for today on route: $routeName',
          relatedRouteId: routeId,
        );
      }

      print('✅ Notified users about collector finishing');
    } catch (e) {
      print('Error notifying users about collector finish: $e');
    }
  }

  /// Notify user when they add a new garbage pin
  Future<void> notifyGarbageAdded(String binId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await addNotification(
        userId: user.uid,
        type: TYPE_GARBAGE_ADDED,
        message: 'Garbage pin successfully added to the map',
        relatedBinId: binId,
      );
    } catch (e) {
      print('Error notifying garbage added: $e');
    }
  }

  /// Notify user when pickup is scheduled
  Future<void> notifyPickupScheduled({
    required String userId,
    required DateTime pickupDate,
    required String location,
  }) async {
    try {
      final dateStr =
          '${pickupDate.month}/${pickupDate.day}/${pickupDate.year}';
      await addNotification(
        userId: userId,
        type: TYPE_PICKUP_SCHEDULED,
        message: 'Pickup scheduled for $dateStr at $location',
        metadata: {
          'pickupDate': pickupDate.toIso8601String(),
          'location': location,
        },
      );
    } catch (e) {
      print('Error notifying pickup scheduled: $e');
    }
  }
}
