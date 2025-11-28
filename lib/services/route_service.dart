import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';

class RouteService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Create a new route
  Future<String> createRoute({
    required String routeName,
    required List<LatLng> routePoints,
    String? description,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final routeData = {
        'routeName': routeName,
        'collectorId': user.uid,
        'routePoints': routePoints
            .map((point) => {
                  'latitude': point.latitude,
                  'longitude': point.longitude,
                })
            .toList(),
        'description': description ?? '',
        'createdAt': FieldValue.serverTimestamp(),
        'lastUsed': FieldValue.serverTimestamp(),
        'isActive': true,
      };

      final docRef =
          await _firestore.collection('collector_routes').add(routeData);
      return docRef.id;
    } catch (e) {
      throw Exception('Failed to create route: $e');
    }
  }

  // Update an existing route
  Future<void> updateRoute({
    required String routeId,
    String? routeName,
    List<LatLng>? routePoints,
    String? description,
  }) async {
    try {
      final Map<String, dynamic> updateData = {
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (routeName != null) updateData['routeName'] = routeName;
      if (description != null) updateData['description'] = description;
      if (routePoints != null) {
        updateData['routePoints'] = routePoints
            .map((point) => {
                  'latitude': point.latitude,
                  'longitude': point.longitude,
                })
            .toList();
      }

      await _firestore
          .collection('collector_routes')
          .doc(routeId)
          .update(updateData);
    } catch (e) {
      throw Exception('Failed to update route: $e');
    }
  }

  // Delete a route
  Future<void> deleteRoute(String routeId) async {
    try {
      await _firestore.collection('collector_routes').doc(routeId).delete();
    } catch (e) {
      throw Exception('Failed to delete route: $e');
    }
  }

  // Get all routes for current collector
  Stream<QuerySnapshot> getCollectorRoutes() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Stream.empty();
    }

    return _firestore
        .collection('collector_routes')
        .where('collectorId', isEqualTo: user.uid)
        .snapshots();
  }

  // Get a specific route
  Future<DocumentSnapshot> getRoute(String routeId) async {
    return await _firestore.collection('collector_routes').doc(routeId).get();
  }

  // Get the active route for the current collector
  Future<Map<String, dynamic>?> getActiveRoute() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return null;

      // First check if there's a currently selected active route
      final activeSnapshot = await _firestore
          .collection('collector_routes')
          .where('collectorId', isEqualTo: user.uid)
          .where('isActive', isEqualTo: true)
          .orderBy('lastUsed', descending: true)
          .limit(1)
          .get();

      if (activeSnapshot.docs.isNotEmpty) {
        final doc = activeSnapshot.docs.first;
        final data = doc.data();
        return {
          'id': doc.id,
          'name': data['routeName'],
          'points': data['routePoints'],
        };
      }

      return null;
    } catch (e) {
      print('Error getting active route: $e');
      return null;
    }
  }

  // Update last used timestamp
  Future<void> markRouteAsUsed(String routeId) async {
    try {
      await _firestore.collection('collector_routes').doc(routeId).update({
        'lastUsed': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Failed to update route usage: $e');
    }
  }

  // Get garbage reports along a route (within a certain distance)
  Future<List<Map<String, dynamic>>> getGarbageAlongRoute({
    required String routeId,
    double maxDistanceKm = 0.02, // 20 meters default
  }) async {
    try {
      final routeDoc = await getRoute(routeId);
      if (!routeDoc.exists) return [];

      final routeData = routeDoc.data() as Map<String, dynamic>;
      final routePoints = (routeData['routePoints'] as List)
          .map((point) => LatLng(
                point['latitude'] as double,
                point['longitude'] as double,
              ))
          .toList();

      // Get all pending garbage reports
      final garbageSnapshot = await _firestore
          .collection('garbage_reports')
          .where('status', isEqualTo: 'pending')
          .get();

      final garbageAlongRoute = <Map<String, dynamic>>[];
      const distance = Distance();

      for (var doc in garbageSnapshot.docs) {
        final data = doc.data();
        final garbageLocation = LatLng(
          data['latitude'] as double,
          data['longitude'] as double,
        );

        // Check if garbage is within maxDistanceKm of any route segment
        bool isAlongRoute = false;
        double minDistance = double.infinity;

        // Check distance to each route segment
        for (int i = 0; i < routePoints.length - 1; i++) {
          final segmentStart = routePoints[i];
          final segmentEnd = routePoints[i + 1];

          // Calculate perpendicular distance from point to line segment
          final distanceToSegment = _distanceToLineSegment(
            garbageLocation,
            segmentStart,
            segmentEnd,
            distance,
          );

          if (distanceToSegment < minDistance) {
            minDistance = distanceToSegment;
          }

          if (distanceToSegment <= maxDistanceKm) {
            isAlongRoute = true;
            break;
          }
        }

        if (isAlongRoute) {
          garbageAlongRoute.add({
            'id': doc.id,
            'lat': data['latitude'],
            'lng': data['longitude'],
            'address': data['address'],
            'issueType': data['issueType'],
            'description': data['description'],
            'timestamp': data['timestamp'],
            'distanceToRoute': minDistance,
          });
        }
      }

      // Sort by distance to route (closest first)
      garbageAlongRoute.sort((a, b) => (a['distanceToRoute'] as double)
          .compareTo(b['distanceToRoute'] as double));

      return garbageAlongRoute;
    } catch (e) {
      throw Exception('Failed to get garbage along route: $e');
    }
  }

  // Calculate perpendicular distance from point to line segment
  double _distanceToLineSegment(
    LatLng point,
    LatLng lineStart,
    LatLng lineEnd,
    Distance distanceCalc,
  ) {
    // If start and end are the same point
    if (lineStart.latitude == lineEnd.latitude &&
        lineStart.longitude == lineEnd.longitude) {
      return distanceCalc.as(LengthUnit.Kilometer, point, lineStart);
    }

    // Calculate perpendicular distance using meters (like trash list screen)
    final distToStart = distanceCalc.as(LengthUnit.Meter, point, lineStart);
    final segmentLength = distanceCalc.as(LengthUnit.Meter, lineStart, lineEnd);

    // Check if projection falls on the segment
    final dotProduct = ((point.latitude - lineStart.latitude) *
            (lineEnd.latitude - lineStart.latitude) +
        (point.longitude - lineStart.longitude) *
            (lineEnd.longitude - lineStart.longitude));

    final lengthSquared = segmentLength * segmentLength;

    if (lengthSquared == 0) return distToStart / 1000.0; // Convert to km

    final t = (dotProduct / lengthSquared).clamp(0.0, 1.0);

    // Find projection point
    final projLat =
        lineStart.latitude + t * (lineEnd.latitude - lineStart.latitude);
    final projLng =
        lineStart.longitude + t * (lineEnd.longitude - lineStart.longitude);
    final projection = LatLng(projLat, projLng);

    // Return distance to projection point in kilometers
    return distanceCalc.as(LengthUnit.Meter, point, projection) / 1000.0;
  }

  // Save recorded route session
  Future<void> saveRecordedSession({
    required String sessionId,
    required List<LatLng> recordedPoints,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore.collection('route_recordings').doc(sessionId).set({
        'collectorId': user.uid,
        'recordedPoints': recordedPoints
            .map((point) => {
                  'latitude': point.latitude,
                  'longitude': point.longitude,
                })
            .toList(),
        'startTime': Timestamp.fromDate(startTime),
        'endTime': Timestamp.fromDate(endTime),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Failed to save recorded session: $e');
    }
  }

  // Get current user ID
  Future<String?> getCurrentUserId() async {
    final user = FirebaseAuth.instance.currentUser;
    return user?.uid;
  }
}
