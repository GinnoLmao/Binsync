import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Service for OSRM API with improved route snapping (5m precision)
class ImprovedRouteSnappingService {
  static const String _baseUrl = 'http://router.project-osrm.org';

  /// Snap point to nearest route with center-of-segment positioning
  /// Returns the snapped location at the CENTER of the nearest route segment
  Future<LatLng?> snapToRouteCenter({
    required LatLng point,
    required List<LatLng> routePoints,
    double maxDistance = 50.0, // meters
  }) async {
    if (routePoints.isEmpty) return null;

    double minDistance = double.infinity;
    LatLng? closestSegmentCenter;

    const distance = Distance();

    // Find the closest route segment
    for (int i = 0; i < routePoints.length - 1; i++) {
      final segmentStart = routePoints[i];
      final segmentEnd = routePoints[i + 1];

      // Calculate perpendicular distance to segment
      final distToSegment = _distanceToLineSegment(
        point,
        segmentStart,
        segmentEnd,
        distance,
      );

      if (distToSegment < minDistance) {
        minDistance = distToSegment;

        // Calculate CENTER of segment (midpoint)
        final centerLat = (segmentStart.latitude + segmentEnd.latitude) / 2;
        final centerLng = (segmentStart.longitude + segmentEnd.longitude) / 2;
        closestSegmentCenter = LatLng(centerLat, centerLng);
      }
    }

    // Only snap if within maxDistance
    if (minDistance <= maxDistance && closestSegmentCenter != null) {
      return closestSegmentCenter;
    }

    return null; // Too far from route
  }

  /// Calculate perpendicular distance from point to line segment
  double _distanceToLineSegment(
    LatLng point,
    LatLng lineStart,
    LatLng lineEnd,
    Distance distanceCalc,
  ) {
    // If start and end are the same point
    if (lineStart.latitude == lineEnd.latitude &&
        lineStart.longitude == lineEnd.longitude) {
      return distanceCalc.as(LengthUnit.Meter, point, lineStart);
    }

    final distToStart = distanceCalc.as(LengthUnit.Meter, point, lineStart);
    final distToEnd = distanceCalc.as(LengthUnit.Meter, point, lineEnd);
    final segmentLength = distanceCalc.as(LengthUnit.Meter, lineStart, lineEnd);

    // Calculate projection
    final dotProduct = ((point.latitude - lineStart.latitude) *
            (lineEnd.latitude - lineStart.latitude) +
        (point.longitude - lineStart.longitude) *
            (lineEnd.longitude - lineStart.longitude));

    final lengthSquared = segmentLength * segmentLength;

    if (lengthSquared == 0) return distToStart;

    final t = (dotProduct / lengthSquared).clamp(0.0, 1.0);

    // Find projection point
    final projLat =
        lineStart.latitude + t * (lineEnd.latitude - lineStart.latitude);
    final projLng =
        lineStart.longitude + t * (lineEnd.longitude - lineStart.longitude);
    final projection = LatLng(projLat, projLng);

    // Return distance to projection point
    return distanceCalc.as(LengthUnit.Meter, point, projection);
  }

  /// Get route from OSRM with high precision (approximately 5m between points)
  /// Uses OSRM's geometries=geojson and overview=full for maximum detail
  Future<List<LatLng>?> getDetailedRoute({
    required List<LatLng> waypoints,
  }) async {
    try {
      if (waypoints.length < 2) return null;

      // Build coordinates string
      final coordinates = waypoints
          .map((point) => '${point.longitude},${point.latitude}')
          .join(';');

      // Request with full detail
      final url = Uri.parse(
        '$_baseUrl/route/v1/driving/$coordinates'
        '?overview=full' // Get full geometry
        '&geometries=geojson' // Use GeoJSON format
        '&steps=true' // Include turn-by-turn steps
        '&annotations=true', // Include detailed annotations
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final geometry = route['geometry'];

          if (geometry != null && geometry['coordinates'] != null) {
            final coordinates = geometry['coordinates'] as List;

            // Convert coordinates to LatLng
            final routePoints = coordinates.map((coord) {
              return LatLng(
                coord[1] as double, // latitude
                coord[0] as double, // longitude
              );
            }).toList();

            // OSRM returns points approximately every 5-10 meters by default
            // If we need even more precision, we can interpolate
            return _interpolatePoints(routePoints, targetDistance: 5.0);
          }
        }
      }

      print('❌ OSRM request failed: ${response.statusCode}');
      return null;
    } catch (e) {
      print('❌ Error getting detailed route: $e');
      return null;
    }
  }

  /// Interpolate points to ensure consistent spacing (e.g., every 5 meters)
  List<LatLng> _interpolatePoints(List<LatLng> points,
      {double targetDistance = 5.0}) {
    if (points.length < 2) return points;

    final interpolated = <LatLng>[points.first];
    const distance = Distance();

    for (int i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];

      final segmentDistance = distance.as(LengthUnit.Meter, start, end);

      // If segment is longer than target, add intermediate points
      if (segmentDistance > targetDistance) {
        final numPoints = (segmentDistance / targetDistance).floor();

        for (int j = 1; j <= numPoints; j++) {
          final t = j / (numPoints + 1);
          final lat = start.latitude + t * (end.latitude - start.latitude);
          final lng = start.longitude + t * (end.longitude - start.longitude);
          interpolated.add(LatLng(lat, lng));
        }
      }

      // Always add the end point (unless it's the last iteration)
      if (i < points.length - 2 || i == points.length - 2) {
        interpolated.add(end);
      }
    }

    // Ensure last point is included
    if (interpolated.last != points.last) {
      interpolated.add(points.last);
    }

    print(
        '✅ Interpolated ${points.length} points to ${interpolated.length} points (target: ${targetDistance}m spacing)');
    return interpolated;
  }

  /// Check if point is near any route (within maxDistance)
  bool isNearRoute({
    required LatLng point,
    required List<LatLng> routePoints,
    double maxDistance = 50.0,
  }) {
    if (routePoints.isEmpty) return false;

    const distance = Distance();

    for (int i = 0; i < routePoints.length - 1; i++) {
      final segmentStart = routePoints[i];
      final segmentEnd = routePoints[i + 1];

      final distToSegment = _distanceToLineSegment(
        point,
        segmentStart,
        segmentEnd,
        distance,
      );

      if (distToSegment <= maxDistance) {
        return true;
      }
    }

    return false;
  }

  /// Find closest route among multiple routes (for areas with 2 separate routes)
  LatLng? snapToClosestRoute({
    required LatLng point,
    required List<List<LatLng>> routes,
    double maxDistance = 50.0,
  }) {
    LatLng? closestSnap;
    double minDistance = double.infinity;

    const distance = Distance();

    for (var routePoints in routes) {
      final snapped = snapToRouteCenterSync(
        point: point,
        routePoints: routePoints,
        maxDistance: maxDistance,
      );

      if (snapped != null) {
        final dist = distance.as(LengthUnit.Meter, point, snapped);
        if (dist < minDistance) {
          minDistance = dist;
          closestSnap = snapped;
        }
      }
    }

    return closestSnap;
  }

  /// Synchronous version of snapToRouteCenter (for immediate use)
  LatLng? snapToRouteCenterSync({
    required LatLng point,
    required List<LatLng> routePoints,
    double maxDistance = 50.0,
  }) {
    if (routePoints.isEmpty) return null;

    double minDistance = double.infinity;
    LatLng? closestSegmentCenter;

    const distance = Distance();

    for (int i = 0; i < routePoints.length - 1; i++) {
      final segmentStart = routePoints[i];
      final segmentEnd = routePoints[i + 1];

      final distToSegment = _distanceToLineSegment(
        point,
        segmentStart,
        segmentEnd,
        distance,
      );

      if (distToSegment < minDistance) {
        minDistance = distToSegment;

        // Calculate CENTER of segment
        final centerLat = (segmentStart.latitude + segmentEnd.latitude) / 2;
        final centerLng = (segmentStart.longitude + segmentEnd.longitude) / 2;
        closestSegmentCenter = LatLng(centerLat, centerLng);
      }
    }

    if (minDistance <= maxDistance && closestSegmentCenter != null) {
      return closestSegmentCenter;
    }

    return null;
  }
}
