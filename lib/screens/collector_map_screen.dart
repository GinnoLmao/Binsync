import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class CollectorMapScreen extends StatefulWidget {
  const CollectorMapScreen({super.key});

  @override
  State<CollectorMapScreen> createState() => _CollectorMapScreenState();
}

class _CollectorMapScreenState extends State<CollectorMapScreen> {
  final MapController _mapController = MapController();
  LatLng _currentLocation = const LatLng(14.5995, 120.9842); // Manila default
  List<Map<String, dynamic>> _garbageLocations = [];
  List<LatLng> _routePoints = [];
  bool _isLoadingRoute = false;
  bool _showRoute = false;
  double _totalDistance = 0.0;
  double _totalDuration = 0.0;

  // Live tracking
  StreamSubscription<Position>? _positionStreamSubscription;
  bool _isFollowing = true;
  bool _isUserDragging = false;

  @override
  void initState() {
    super.initState();
    _startLiveLocationTracking();
    _loadGarbageLocations();
    _listenToGarbageLocations();
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  void _startLiveLocationTracking() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      // Get initial position with best accuracy
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );

      if (mounted) {
        setState(() {
          _currentLocation = LatLng(position.latitude, position.longitude);
        });

        _mapController.move(_currentLocation, 16.0);
      }

      // Start listening to position updates with best accuracy
      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3, // Update every 3 meters for better tracking
      );

      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen((Position position) {
        if (mounted) {
          setState(() {
            _currentLocation = LatLng(position.latitude, position.longitude);
          });

          // Update collector location in Firestore
          _updateCollectorLocation(position.latitude, position.longitude);

          // Auto-follow if enabled and user isn't dragging
          if (_isFollowing && !_isUserDragging) {
            _mapController.move(_currentLocation, _mapController.camera.zoom);
          }
        }
      });
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  Future<void> _updateCollectorLocation(
      double latitude, double longitude) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await FirebaseFirestore.instance
          .collection('active_collectors')
          .doc(user.uid)
          .set({
        'latitude': latitude,
        'longitude': longitude,
        'lastUpdate': FieldValue.serverTimestamp(),
        'userId': user.uid,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error updating collector location: $e');
    }
  }

  Future<void> _loadGarbageLocations() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('garbage_reports')
          .where('status', isEqualTo: 'pending')
          .get();

      final locations = snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'lat': data['latitude'] as double,
          'lng': data['longitude'] as double,
          'address': data['address'] as String,
          'issueType': data['issueType'] as String?,
          'description': data['description'] as String?,
        };
      }).toList();

      setState(() {
        _garbageLocations = locations;
      });
    } catch (e) {
      debugPrint('Error loading garbage locations: $e');
    }
  }

  void _listenToGarbageLocations() {
    FirebaseFirestore.instance
        .collection('garbage_reports')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snapshot) {
      final locations = snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'lat': data['latitude'] as double,
          'lng': data['longitude'] as double,
          'address': data['address'] as String,
          'issueType': data['issueType'] as String?,
          'description': data['description'] as String?,
        };
      }).toList();

      if (mounted) {
        setState(() {
          _garbageLocations = locations;
        });

        // Auto-recalculate route if it was showing
        if (_showRoute && locations.isNotEmpty) {
          _calculateRoute();
        }
      }
    });
  }

  Future<void> _calculateRoute() async {
    if (_garbageLocations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No garbage locations to route'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isLoadingRoute = true;
      _routePoints = [];
    });

    try {
      // Create list of coordinates starting with current location
      List<String> coordinates = [
        '${_currentLocation.longitude},${_currentLocation.latitude}'
      ];

      // Add all garbage locations
      for (var location in _garbageLocations) {
        coordinates.add('${location['lng']},${location['lat']}');
      }

      // Build OSRM API URL for route optimization
      final coordinatesString = coordinates.join(';');
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$coordinatesString?overview=full&geometries=geojson',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final geometry = route['geometry']['coordinates'] as List;

          final routePoints = geometry.map((coord) {
            return LatLng(coord[1] as double, coord[0] as double);
          }).toList();

          final distance = route['distance'] as num; // meters
          final duration = route['duration'] as num; // seconds

          setState(() {
            _routePoints = routePoints;
            _totalDistance = distance / 1000; // convert to km
            _totalDuration = duration / 60; // convert to minutes
            _showRoute = true;
            _isLoadingRoute = false;
          });

          // Fit bounds to show entire route
          if (_routePoints.isNotEmpty) {
            final bounds = LatLngBounds.fromPoints(_routePoints);
            _mapController.fitCamera(
              CameraFit.bounds(
                bounds: bounds,
                padding: const EdgeInsets.all(50),
              ),
            );
          }

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Route: ${_totalDistance.toStringAsFixed(1)} km, ${_totalDuration.toStringAsFixed(0)} min',
                ),
                backgroundColor: const Color(0xFF00A86B),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        } else {
          throw 'No route found';
        }
      } else {
        throw 'Failed to get route: ${response.statusCode}';
      }
    } catch (e) {
      setState(() {
        _isLoadingRoute = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error calculating route: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _clearRoute() {
    setState(() {
      _routePoints = [];
      _showRoute = false;
      _totalDistance = 0.0;
      _totalDuration = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: const Text(
          'Collection Map',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {
              _loadGarbageLocations();
              if (_showRoute) {
                _calculateRoute();
              }
            },
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
              initialZoom: 16.0,
              minZoom: 3.0,
              maxZoom: 18.0,
              initialRotation: 0.0, // Start with north up
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onPositionChanged: (position, hasGesture) {
                // Detect user dragging
                if (hasGesture) {
                  setState(() {
                    _isUserDragging = true;
                    _isFollowing = false;
                  });
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.binsync',
              ),

              // Route polyline
              if (_showRoute && _routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 4.0,
                      color: Colors.blue,
                    ),
                  ],
                ),

              // Garbage location markers
              MarkerLayer(
                markers: [
                  // Current location marker (pulsing effect)
                  Marker(
                    width: 50.0,
                    height: 50.0,
                    point: _currentLocation,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Outer circle (pulsing)
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.blue.withOpacity(0.2),
                          ),
                        ),
                        // Inner circle
                        Container(
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.blue,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.blue,
                                blurRadius: 10,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Garbage markers (rotate: false to prevent rotation with map)
                  ..._garbageLocations.map((location) {
                    return Marker(
                      width: 50.0,
                      height: 50.0,
                      point: LatLng(location['lat'], location['lng']),
                      rotate: false, // Keep pins upright
                      alignment: const Alignment(
                          0.15, -0.85), // Offset for pin tip position
                      child: GestureDetector(
                        onTap: () => _showLocationDetails(location),
                        child: Image.asset(
                          'assets/images/garbage_pin.png',
                          width: 50,
                          height: 50,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ],
          ),

          // Info card at top
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildInfoItem(
                      Icons.pin_drop,
                      '${_garbageLocations.length}',
                      'Locations',
                    ),
                    if (_showRoute) ...[
                      _buildInfoItem(
                        Icons.route,
                        '${_totalDistance.toStringAsFixed(1)} km',
                        'Distance',
                      ),
                      _buildInfoItem(
                        Icons.access_time,
                        '${_totalDuration.toStringAsFixed(0)} min',
                        'Duration',
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // Control buttons (top right)
          Positioned(
            top: 80,
            right: 16,
            child: Column(
              children: [
                // North alignment button
                FloatingActionButton(
                  heroTag: 'north',
                  onPressed: () {
                    _mapController.rotate(0.0);
                  },
                  mini: true,
                  backgroundColor: Colors.white,
                  child: const Icon(
                    Icons.navigation,
                    color: Color(0xFF00A86B),
                  ),
                ),
                if (!_isFollowing) ...[
                  const SizedBox(height: 8),
                  // Follow button
                  FloatingActionButton(
                    heroTag: 'follow',
                    onPressed: () {
                      setState(() {
                        _isFollowing = true;
                        _isUserDragging = false;
                      });
                      _mapController.move(_currentLocation, 16.0);
                    },
                    backgroundColor: Colors.white,
                    child: const Icon(
                      Icons.my_location,
                      color: Color(0xFF00A86B),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Route buttons at bottom
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoadingRoute ? null : _calculateRoute,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A86B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 4,
                    ),
                    icon: _isLoadingRoute
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Icon(Icons.route),
                    label: Text(
                      _isLoadingRoute ? 'Calculating...' : 'Calculate Route',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                if (_showRoute) ...[
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _clearRoute,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 4,
                    ),
                    child: const Icon(Icons.clear),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF00A86B), size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  void _showLocationDetails(Map<String, dynamic> location) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00A86B).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.delete,
                    color: Color(0xFF00A86B),
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        location['issueType'] ?? 'Garbage Report',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        location['address'],
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (location['description'] != null &&
                location['description'].isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Description:',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                location['description'],
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[700],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _mapController.move(
                        LatLng(location['lat'], location['lng']),
                        16.0,
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: Color(0xFF00A86B)),
                    ),
                    icon:
                        const Icon(Icons.location_on, color: Color(0xFF00A86B)),
                    label: const Text(
                      'View on Map',
                      style: TextStyle(color: Color(0xFF00A86B)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _markAsCollected(location['id']);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A86B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.check_circle),
                    label: const Text('Collected'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _markAsCollected(String reportId) async {
    // Get report details first
    final reportDoc = await FirebaseFirestore.instance
        .collection('garbage_reports')
        .doc(reportId)
        .get();

    if (!reportDoc.exists) return;

    final reportData = reportDoc.data() as Map<String, dynamic>;
    final reportedBy = reportData['reportedBy'] as String?;
    final address = reportData['address'] as String?;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark as Collected'),
        content: const Text('Have you collected this garbage?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                final collectorId = FirebaseAuth.instance.currentUser?.uid;

                // Update report status
                await FirebaseFirestore.instance
                    .collection('garbage_reports')
                    .doc(reportId)
                    .update({
                  'status': 'collected',
                  'collectorId': collectorId ?? 'unknown',
                  'collectedAt': FieldValue.serverTimestamp(),
                });

                // Send notification to user
                if (reportedBy != null && reportedBy != 'anonymous') {
                  await FirebaseFirestore.instance
                      .collection('notifications')
                      .add({
                    'userId': reportedBy,
                    'title': 'Garbage Collected! ✅',
                    'message':
                        'Your garbage report at $address has been collected.',
                    'type': 'collection',
                    'reportId': reportId,
                    'timestamp': FieldValue.serverTimestamp(),
                    'read': false,
                  });
                }

                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Marked as collected! User notified.'),
                      backgroundColor: Color(0xFF00A86B),
                      duration: Duration(seconds: 2),
                    ),
                  );
                  _loadGarbageLocations();
                  _clearRoute();
                }
              } catch (e) {
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A86B),
            ),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }
}
