import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:isolate';

/// Service to manage collector sessions with background location tracking
class CollectorSessionService {
  static final CollectorSessionService _instance =
      CollectorSessionService._internal();
  factory CollectorSessionService() => _instance;
  CollectorSessionService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _currentSessionId;
  DateTime? _sessionStartTime;
  List<Map<String, dynamic>> _locationHistory = [];
  Timer? _locationTimer;
  StreamSubscription<Position>? _positionSubscription;
  double _totalDistance = 0.0;
  LatLng? _lastLocation;
  int _binsCollected = 0;
  String? _activeRouteId;
  String? _activeRouteName;
  List<String> _collectedBinIds = [];
  List<Map<String, dynamic>> _missedBins = [];

  bool get isSessionActive => _currentSessionId != null;
  String? get currentSessionId => _currentSessionId;
  double get totalDistance => _totalDistance;
  int get binsCollected => _binsCollected;
  DateTime? get sessionStartTime => _sessionStartTime;

  Duration get sessionDuration {
    if (_sessionStartTime == null) return Duration.zero;
    return DateTime.now().difference(_sessionStartTime!);
  }

  /// Start a new collecting session with background tracking
  Future<String?> startSession({
    required String routeId,
    required String routeName,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not authenticated');

      _activeRouteId = routeId;
      _activeRouteName = routeName;
      _sessionStartTime = DateTime.now();
      _totalDistance = 0.0;
      _binsCollected = 0;
      _locationHistory = [];
      _lastLocation = null;
      _collectedBinIds = [];
      _missedBins = [];

      // Create session document
      final sessionDoc = await _firestore.collection('collector_sessions').add({
        'collectorId': user.uid,
        'routeId': routeId,
        'routeName': routeName,
        'startTime': FieldValue.serverTimestamp(),
        'endTime': null,
        'binsCollected': 0,
        'totalBins': 0,
        'distanceTraveled': 0.0,
        'status': 'active',
        'locationHistory': [],
        'collectedBins': [],
        'missedBins': [],
      });

      _currentSessionId = sessionDoc.id;

      // Start background location tracking
      await _startBackgroundLocationTracking();

      // Update collector's active status
      await _firestore.collection('active_collectors').doc(user.uid).set({
        'isActive': true,
        'sessionId': _currentSessionId,
        'routeId': routeId,
        'routeName': routeName,
        'startTime': FieldValue.serverTimestamp(),
        'lastUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('✅ Session started: $_currentSessionId');
      return _currentSessionId;
    } catch (e) {
      print('❌ Error starting session: $e');
      return null;
    }
  }

  /// Start background location tracking with foreground service
  Future<void> _startBackgroundLocationTracking() async {
    // Initialize foreground task
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'binsync_tracking',
        channelName: 'Binsync Route Tracking',
        channelDescription: 'Tracking your collection route',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000), // 5 seconds
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    // Start foreground service
    await FlutterForegroundTask.startService(
      notificationTitle: 'Binsync Tracking Active',
      notificationText: 'Recording your collection route',
      callback: _startLocationTracking,
    );
  }

  /// Callback for location tracking (runs in background)
  @pragma('vm:entry-point')
  static void _startLocationTracking() {
    FlutterForegroundTask.setTaskHandler(_LocationTrackingHandler());
  }

  /// Update location in session (called every 5 seconds)
  Future<void> _recordLocation(double lat, double lng) async {
    if (_currentSessionId == null) return;

    final currentLocation = LatLng(lat, lng);
    final timestamp = DateTime.now();

    // Calculate distance from last location
    if (_lastLocation != null) {
      const distance = Distance();
      final distanceMeters = distance.as(
        LengthUnit.Meter,
        _lastLocation!,
        currentLocation,
      );
      _totalDistance += distanceMeters;
    }

    _lastLocation = currentLocation;

    // Add to location history
    _locationHistory.add({
      'latitude': lat,
      'longitude': lng,
      'timestamp': timestamp.toIso8601String(),
    });

    // Update session document every 5 locations (25 seconds)
    if (_locationHistory.length % 5 == 0) {
      try {
        await _firestore
            .collection('collector_sessions')
            .doc(_currentSessionId)
            .update({
          'locationHistory': FieldValue.arrayUnion(_locationHistory),
          'distanceTraveled': _totalDistance,
          'lastUpdate': FieldValue.serverTimestamp(),
        });

        // Also update active_collectors for live user tracking
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await _firestore
              .collection('active_collectors')
              .doc(user.uid)
              .update({
            'latitude': lat,
            'longitude': lng,
            'lastUpdate': FieldValue.serverTimestamp(),
          });

          // Update daily tracking_sessions for real-time stats display
          await _updateDailyTrackingSession(user.uid);
        }

        _locationHistory = []; // Clear buffer after upload
      } catch (e) {
        print('Error updating session location: $e');
      }
    }
  }

  /// Add collected bin to session
  Future<void> addCollectedBin(String binId) async {
    if (_currentSessionId == null) return;

    _binsCollected++;
    _collectedBinIds.add(binId);

    try {
      await _firestore
          .collection('collector_sessions')
          .doc(_currentSessionId)
          .update({
        'binsCollected': _binsCollected,
        'collectedBins': FieldValue.arrayUnion([binId]),
      });

      // Update daily tracking session with new bin count
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _updateDailyTrackingSession(user.uid);
      }
    } catch (e) {
      print('Error updating bins collected: $e');
    }
  }

  /// Add a missed bin to the session
  Future<void> addMissedBin(String binId, String address) async {
    if (_currentSessionId == null) return;

    final missedBin = {'binId': binId, 'address': address};
    _missedBins.add(missedBin);

    try {
      await _firestore
          .collection('collector_sessions')
          .doc(_currentSessionId)
          .update({
        'missedBins': FieldValue.arrayUnion([missedBin]),
      });
    } catch (e) {
      print('Error adding missed bin: $e');
    }
  }

  /// Finish the current session
  Future<Map<String, dynamic>?> finishSession({
    required int totalBins,
    Duration? duration,
  }) async {
    if (_currentSessionId == null) return null;

    try {
      // Stop background tracking
      await _stopBackgroundLocationTracking();

      // Upload any remaining location history
      if (_locationHistory.isNotEmpty) {
        await _firestore
            .collection('collector_sessions')
            .doc(_currentSessionId)
            .update({
          'locationHistory': FieldValue.arrayUnion(_locationHistory),
        });
      }

      // Use provided duration or calculate from session start time
      final sessionDuration =
          duration ?? DateTime.now().difference(_sessionStartTime!);

      // Update session document
      await _firestore
          .collection('collector_sessions')
          .doc(_currentSessionId)
          .update({
        'endTime': FieldValue.serverTimestamp(),
        'status': 'completed',
        'distanceTraveled': _totalDistance,
        'binsCollected': _binsCollected,
        'totalBins': totalBins,
        'duration': sessionDuration.inSeconds,
      });

      // Update active collector status
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await _firestore.collection('active_collectors').doc(user.uid).update({
          'isActive': false,
          'sessionId': null,
        });
      }

      // Create daily backup
      await _backupDailyStats(
        distance: _totalDistance,
        duration: sessionDuration,
        binsCollected: _binsCollected,
      );

      final sessionSummary = {
        'sessionId': _currentSessionId,
        'duration': sessionDuration.inMinutes,
        'distance': _totalDistance / 1000, // Convert to km
        'binsCollected': _binsCollected,
        'totalBins': totalBins,
        'collectedBins': _collectedBinIds,
        'missedBins': _missedBins,
      };

      // Reset session
      _currentSessionId = null;
      _sessionStartTime = null;
      _locationHistory = [];
      _totalDistance = 0.0;
      _binsCollected = 0;
      _lastLocation = null;
      _collectedBinIds = [];
      _missedBins = [];

      return sessionSummary;
    } catch (e) {
      print('❌ Error finishing session: $e');
      return null;
    }
  }

  /// Update daily tracking_sessions document for real-time stats display
  Future<void> _updateDailyTrackingSession(String userId) async {
    try {
      final today = DateTime.now();
      final dateStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final docId = '${userId}_$dateStr';

      print('📝 Updating tracking_sessions doc: $docId');

      // Calculate current session duration
      final currentDuration = _sessionStartTime != null
          ? DateTime.now().difference(_sessionStartTime!)
          : Duration.zero;

      print('⏱️ Current session duration: ${currentDuration.inSeconds}s');
      print('📏 Current session distance: ${_totalDistance}m');
      print('🗑️ Current session bins: $_binsCollected');

      // Get all completed sessions for today to calculate base values
      final todayStart = DateTime(today.year, today.month, today.day);
      final todayEnd = todayStart.add(const Duration(days: 1));

      final completedSessions = await _firestore
          .collection('collector_sessions')
          .where('collectorId', isEqualTo: userId)
          .where('status', isEqualTo: 'completed')
          .where('startTime',
              isGreaterThanOrEqualTo: Timestamp.fromDate(todayStart))
          .where('startTime', isLessThan: Timestamp.fromDate(todayEnd))
          .get();

      print(
          '✅ Found ${completedSessions.docs.length} completed sessions today');

      // Sum up completed sessions
      double completedDistance = 0.0;
      int completedDuration = 0;
      int completedBins = 0;

      for (var doc in completedSessions.docs) {
        final data = doc.data() as Map<String, dynamic>;
        completedDistance += (data['distanceTraveled'] ?? 0.0) as double;
        completedDuration += (data['duration'] ?? 0) as int;
        completedBins += (data['binsCollected'] ?? 0) as int;
      }

      // Add current active session data
      final totalDistance = completedDistance + _totalDistance;
      final totalDuration = completedDuration + currentDuration.inSeconds;
      final totalBins = completedBins + _binsCollected;

      print(
          '📊 TOTAL - Distance: ${totalDistance}m, Duration: ${totalDuration}s, Bins: $totalBins');

      // Update or create tracking_sessions document
      final docRef = _firestore.collection('tracking_sessions').doc(docId);
      await docRef.set({
        'collectorId': userId,
        'date': dateStr,
        'dateTimestamp': Timestamp.fromDate(today),
        'distance': totalDistance,
        'duration': totalDuration,
        'binsCollected': totalBins,
        'lastUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('✅ Successfully updated tracking_sessions document');
    } catch (e) {
      print('❌ Error updating daily tracking session: $e');
    }
  }

  /// Stop background location tracking
  Future<void> _stopBackgroundLocationTracking() async {
    _locationTimer?.cancel();
    _positionSubscription?.cancel();
    await FlutterForegroundTask.stopService();
  }

  /// Backup daily stats for weekly calculations
  Future<void> _backupDailyStats({
    required double distance,
    required Duration duration,
    required int binsCollected,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final today = DateTime.now();
      final dateStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final docId = '${user.uid}_$dateStr';

      // Check if document exists for today
      final docRef = _firestore.collection('daily_stats_backup').doc(docId);
      final docSnapshot = await docRef.get();

      if (docSnapshot.exists) {
        // Increment existing stats
        await docRef.update({
          'distanceTraveled': FieldValue.increment(distance),
          'duration': FieldValue.increment(duration.inSeconds),
          'binsCollected': FieldValue.increment(binsCollected),
          'sessionsCount': FieldValue.increment(1),
          'lastUpdate': FieldValue.serverTimestamp(),
        });
      } else {
        // Create new document for today
        await docRef.set({
          'collectorId': user.uid,
          'date': dateStr,
          'dateTimestamp': Timestamp.fromDate(today),
          'distanceTraveled': distance,
          'duration': duration.inSeconds,
          'binsCollected': binsCollected,
          'sessionsCount': 1,
          'createdAt': FieldValue.serverTimestamp(),
          'lastUpdate': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      print('Error backing up daily stats: $e');
    }
  }

  /// Get current session data
  Stream<DocumentSnapshot>? getCurrentSessionStream() {
    if (_currentSessionId == null) return null;
    return _firestore
        .collection('collector_sessions')
        .doc(_currentSessionId)
        .snapshots();
  }

  /// Get all sessions for a collector (with 2-month limit)
  Stream<QuerySnapshot> getCollectorSessions() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Stream.empty();

    final twoMonthsAgo = DateTime.now().subtract(const Duration(days: 60));

    return _firestore
        .collection('collector_sessions')
        .where('collectorId', isEqualTo: user.uid)
        .where('startTime', isGreaterThan: Timestamp.fromDate(twoMonthsAgo))
        .orderBy('startTime', descending: true)
        .snapshots();
  }

  /// Delete old sessions (older than 2 months)
  Future<void> cleanupOldSessions() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final twoMonthsAgo = DateTime.now().subtract(const Duration(days: 60));

      final oldSessions = await _firestore
          .collection('collector_sessions')
          .where('collectorId', isEqualTo: user.uid)
          .where('startTime', isLessThan: Timestamp.fromDate(twoMonthsAgo))
          .get();

      for (var doc in oldSessions.docs) {
        await doc.reference.delete();
      }

      print('🗑️ Cleaned up ${oldSessions.docs.length} old sessions');
    } catch (e) {
      print('Error cleaning up old sessions: $e');
    }
  }
}

/// Handler for background location tracking
class _LocationTrackingHandler extends TaskHandler {
  StreamSubscription<Position>? _positionSubscription;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('🚀 Background location tracking started');

    // Start listening to location updates
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      // Location updates will be processed here
      // In production, you would send this to a service or database
    });
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // This is called every 5 seconds (as configured in foregroundTaskOptions)
    // The actual location updates are handled in the stream listener
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    print('🛑 Background location tracking stopped');
    await _positionSubscription?.cancel();
  }
}
