import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async';

class CollectorTrackingService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  StreamSubscription<Position>? _positionStreamSubscription;
  DateTime? _startTime;
  LatLng? _startPosition;
  double _totalDistanceMeters = 0.0;
  bool _isTracking = false;
  bool _autoStartTriggered = false;

  // Callbacks for UI updates
  Function(double distance, Duration duration)? onUpdate;

  bool get isTracking => _isTracking;

  // Start manual tracking
  Future<void> startTracking() async {
    if (_isTracking) return;

    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // Get current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );

      _startTime = DateTime.now();
      _startPosition = LatLng(position.latitude, position.longitude);
      _totalDistanceMeters = 0.0;
      _isTracking = true;
      _autoStartTriggered = false;

      // Save tracking session to Firestore
      await _firestore.collection('tracking_sessions').doc(user.uid).set({
        'collectorId': user.uid,
        'startTime': FieldValue.serverTimestamp(),
        'startLat': position.latitude,
        'startLng': position.longitude,
        'totalDistance': 0.0,
        'status': 'active',
      });

      // Start listening to position changes
      _startPositionTracking();
    } catch (e) {
      print('Error starting tracking: $e');
    }
  }

  void _startPositionTracking() {
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 10, // Update every 10 meters
    );

    LatLng? lastPosition = _startPosition;

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) async {
      if (!_isTracking) return;

      final currentPosition = LatLng(position.latitude, position.longitude);

      // Calculate distance from last position
      if (lastPosition != null) {
        const Distance distance = Distance();
        final distanceMeters = distance.as(
          LengthUnit.Meter,
          lastPosition!,
          currentPosition,
        );

        _totalDistanceMeters += distanceMeters;

        // Update Firestore
        final user = _auth.currentUser;
        if (user != null) {
          await _firestore
              .collection('tracking_sessions')
              .doc(user.uid)
              .update({
            'totalDistance': _totalDistanceMeters,
            'currentLat': position.latitude,
            'currentLng': position.longitude,
            'lastUpdate': FieldValue.serverTimestamp(),
          });
        }

        // Notify UI
        if (_startTime != null && onUpdate != null) {
          final duration = DateTime.now().difference(_startTime!);
          onUpdate!(_totalDistanceMeters, duration);
        }
      }

      lastPosition = currentPosition;
    });
  }

  // Check if collector has moved 250m and auto-start if needed
  Future<void> checkAutoStart(LatLng currentPosition) async {
    if (_isTracking || _autoStartTriggered) return;

    if (_startPosition == null) {
      _startPosition = currentPosition;
      return;
    }

    final Distance distance = Distance();
    final distanceMeters = distance.as(
      LengthUnit.Meter,
      _startPosition!,
      currentPosition,
    );

    if (distanceMeters >= 250) {
      _autoStartTriggered = true;
      await startTracking();
    }
  }

  // Stop tracking
  Future<void> stopTracking() async {
    if (!_isTracking) return;

    _isTracking = false;
    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;

    final user = _auth.currentUser;
    if (user != null && _startTime != null) {
      final endTime = DateTime.now();
      final duration = endTime.difference(_startTime!);

      await _firestore.collection('tracking_sessions').doc(user.uid).update({
        'endTime': FieldValue.serverTimestamp(),
        'totalDistance': _totalDistanceMeters,
        'durationSeconds': duration.inSeconds,
        'status': 'completed',
      });
    }
  }

  // Get today's tracking data
  Future<Map<String, dynamic>> getTodayTrackingData() async {
    final user = _auth.currentUser;
    if (user == null) {
      return {
        'distance': 0.0,
        'duration': Duration.zero,
        'completionRate': 0.0,
      };
    }

    try {
      // Use date-based document ID pattern
      final today = DateTime.now();
      final dateStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final docId = '${user.uid}_$dateStr';

      final doc =
          await _firestore.collection('tracking_sessions').doc(docId).get();

      if (!doc.exists) {
        return {
          'distance': 0.0,
          'duration': Duration.zero,
          'completionRate': 0.0,
        };
      }

      final data = doc.data() as Map<String, dynamic>;
      final distance = (data['distance'] ?? 0.0) as double;

      // Duration is stored in seconds
      final durationSeconds = (data['duration'] ?? 0) as int;
      final duration = Duration(seconds: durationSeconds);

      // Get completion rate from collected garbage
      final routeGarbageQuery = await _firestore
          .collection('garbage_reports')
          .where('status', isEqualTo: 'pending')
          .get();
      final totalGarbage = routeGarbageQuery.docs.length;

      final collectedGarbageQuery = await _firestore
          .collection('garbage_reports')
          .where('collectorId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'collected')
          .get();
      final collectedGarbage = collectedGarbageQuery.docs.length;

      final completionRate =
          totalGarbage > 0 ? (collectedGarbage / totalGarbage * 100) : 0.0;

      return {
        'distance': distance,
        'duration': duration,
        'completionRate': completionRate,
      };
    } catch (e) {
      print('Error getting tracking data: $e');
      return {
        'distance': 0.0,
        'duration': Duration.zero,
        'completionRate': 0.0,
      };
    }
  }

  // Dispose
  void dispose() {
    _positionStreamSubscription?.cancel();
  }
}
