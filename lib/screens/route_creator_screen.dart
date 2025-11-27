import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/route_service.dart';

class RouteCreatorScreen extends StatefulWidget {
  const RouteCreatorScreen({super.key});

  @override
  State<RouteCreatorScreen> createState() => _RouteCreatorScreenState();
}

class _RouteCreatorScreenState extends State<RouteCreatorScreen> {
  final MapController _mapController = MapController();
  final RouteService _routeService = RouteService();
  final TextEditingController _routeNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  LatLng _currentLocation = const LatLng(14.5995, 120.9842);
  List<LatLng> _routePoints = [];
  final List<LatLng> _waypoints = []; // User-tapped waypoints
  List<LatLng> _snappedRoute = []; // Road-snapped route
  bool _isLoading = false;
  bool _isSnapping = false;

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _routeNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (mounted) {
        setState(() {
          _currentLocation = LatLng(position.latitude, position.longitude);
        });
        _mapController.move(_currentLocation, 15.0);
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  void _handleMapTap(TapPosition tapPosition, LatLng point) {
    _waypoints.add(point);
    if (_waypoints.length >= 2) {
      _snapRouteToRoads();
    } else {
      setState(() {
        _routePoints = List.from(_waypoints);
      });
    }
  }

  Future<void> _snapRouteToRoads() async {
    if (_waypoints.length < 2) return;

    setState(() => _isSnapping = true);

    try {
      // Build coordinates string for OSRM API
      String coordinates = _waypoints
          .map((point) => '${point.longitude},${point.latitude}')
          .join(';');

      // Use OSRM routing API to get road-snapped route
      final url =
          'https://router.project-osrm.org/route/v1/driving/$coordinates?overview=full&geometries=geojson';

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 'Ok' && data['routes'] != null) {
          final coordinates =
              data['routes'][0]['geometry']['coordinates'] as List;

          final snappedPoints = coordinates
              .map((coord) => LatLng(coord[1] as double, coord[0] as double))
              .toList();

          setState(() {
            _snappedRoute = snappedPoints;
            _routePoints = snappedPoints;
          });
        }
      }
    } catch (e) {
      debugPrint('Error snapping route to roads: $e');
      // Fall back to straight lines if snapping fails
      setState(() {
        _routePoints = List.from(_waypoints);
      });
    } finally {
      setState(() => _isSnapping = false);
    }
  }

  void _undoLastPoint() {
    if (_waypoints.isNotEmpty) {
      setState(() {
        _waypoints.removeLast();
        if (_waypoints.length >= 2) {
          _snapRouteToRoads();
        } else {
          _routePoints = List.from(_waypoints);
        }
      });
    }
  }

  void _clearRoute() {
    setState(() {
      _routePoints.clear();
      _waypoints.clear();
      _snappedRoute.clear();
    });
  }

  // Densify route by adding intermediate points
  List<LatLng> _densifyRoute(List<LatLng> points, double maxDistanceKm) {
    if (points.length < 2) return points;

    final densified = <LatLng>[];
    const distance = Distance();

    for (int i = 0; i < points.length - 1; i++) {
      final start = points[i];
      final end = points[i + 1];
      
      densified.add(start);
      
      final segmentDistance = distance.as(LengthUnit.Kilometer, start, end);
      
      // If segment is longer than maxDistance, add intermediate points
      if (segmentDistance > maxDistanceKm) {
        final numPoints = (segmentDistance / maxDistanceKm).ceil();
        
        for (int j = 1; j < numPoints; j++) {
          final t = j / numPoints;
          final lat = start.latitude + t * (end.latitude - start.latitude);
          final lng = start.longitude + t * (end.longitude - start.longitude);
          densified.add(LatLng(lat, lng));
        }
      }
    }
    
    // Add the last point
    densified.add(points.last);
    
    return densified;
  }

  Future<void> _saveRoute() async {
    if (_routePoints.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add at least 2 points to create a route'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final routeName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Route'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _routeNameController,
              decoration: const InputDecoration(
                labelText: 'Route Name',
                hintText: 'e.g., Morning Route',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (Optional)',
                hintText: 'e.g., Downtown area',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (_routeNameController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a route name'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              Navigator.pop(context, _routeNameController.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A86B),
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (routeName == null || routeName.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      // Densify route points to ensure good coverage (add points every ~25m)
      final densifiedPoints = _densifyRoute(_routePoints, 0.025); // 25 meters
      
      await _routeService.createRoute(
        routeName: routeName,
        routePoints: densifiedPoints,
        description: _descriptionController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Route saved successfully!'),
            backgroundColor: Color(0xFF00A86B),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save route: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: const Text(
          'Create Route Manually',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_routePoints.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.save, color: Colors.white),
              onPressed: _isLoading ? null : _saveRoute,
            ),
        ],
      ),
      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation,
              initialZoom: 15.0,
              onTap: _handleMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.binsync.app',
              ),
              // Route polyline (road-snapped)
              if (_routePoints.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 5.0,
                      color: const Color(0xFF00A86B),
                    ),
                  ],
                ),
              // Waypoint markers (user-tapped points only)
              MarkerLayer(
                markers: [
                  // Current location marker
                  Marker(
                    point: _currentLocation,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  // Waypoint markers (user-tapped points)
                  ..._waypoints.asMap().entries.map((entry) {
                    final index = entry.key;
                    final point = entry.value;
                    final isFirst = index == 0;
                    final isLast = index == _waypoints.length - 1;

                    return Marker(
                      point: point,
                      width: 35,
                      height: 35,
                      child: Container(
                        decoration: BoxDecoration(
                          color: isFirst
                              ? Colors.green
                              : isLast
                                  ? Colors.red
                                  : const Color(0xFF00A86B),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ],
          ),

          // Instructions overlay
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: Color(0xFF00A86B),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tap on the map to add points to your route',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Control buttons
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Row(
              children: [
                if (_waypoints.isNotEmpty) ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isSnapping ? null : _undoLastPoint,
                      icon: const Icon(Icons.undo),
                      label: const Text('Undo'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isSnapping ? null : _clearRoute,
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Point counter
          if (_waypoints.isNotEmpty)
            Positioned(
              bottom: 70,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF00A86B),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_waypoints.length} waypoints',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_isSnapping) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          // Loading overlay
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
