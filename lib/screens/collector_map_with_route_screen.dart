import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/route_service.dart';
import '../services/collector_tracking_service.dart';
import '../services/collector_session_service.dart';
import '../services/user_notification_service.dart';

class CollectorMapWithRouteScreen extends StatefulWidget {
  final String routeId;
  final String routeName;
  final List<LatLng> routePoints;
  final bool showBackButton;
  final VoidCallback? onBackPressed;

  const CollectorMapWithRouteScreen({
    super.key,
    required this.routeId,
    required this.routeName,
    required this.routePoints,
    this.showBackButton = false,
    this.onBackPressed,
  });

  @override
  State<CollectorMapWithRouteScreen> createState() =>
      _CollectorMapWithRouteScreenState();
}

class _CollectorMapWithRouteScreenState
    extends State<CollectorMapWithRouteScreen> {
  final MapController _mapController = MapController();
  final RouteService _routeService = RouteService();
  final CollectorTrackingService _trackingService = CollectorTrackingService();
  final CollectorSessionService _sessionService = CollectorSessionService();

  LatLng _currentLocation = const LatLng(14.5995, 120.9842);
  LatLng? _initialPosition; // Store initial position for 250m check
  List<Map<String, dynamic>> _garbageLocations = [];
  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<QuerySnapshot>? _garbageStreamSubscription;
  bool _isFollowing = true;
  bool _isLoadingGarbage = true;
  int _totalGarbageCount = 0;
  int _collectedCount = 0;
  Map<String, dynamic>? _nextGarbage; // Next garbage to collect
  bool _showStartButton = true; // Show start collecting button
  bool _isSessionActive = false; // Track if collection session is active
  String? _activeSessionId; // Current session ID

  // Timer variables
  DateTime? _sessionStartTime;
  Timer? _timer;
  Duration _elapsedTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    print('🚀 MAP SCREEN INITIALIZED - Route ID: ${widget.routeId}');
    _startLiveLocationTracking();
    _loadGarbageAlongRoute();
    _listenToGarbageUpdates(); // Add real-time listener
    _centerMapOnRoute();
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    _garbageStreamSubscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _listenToGarbageUpdates() {
    print('📡 Setting up real-time garbage listener...');
    // Listen to real-time updates on garbage_reports collection
    _garbageStreamSubscription = FirebaseFirestore.instance
        .collection('garbage_reports')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen(
      (snapshot) {
        print(
            '🔔 GARBAGE UPDATE DETECTED: ${snapshot.docs.length} pending bins');
        // Reload garbage when there are changes
        _loadGarbageAlongRoute();
      },
      onError: (error) {
        print('❌ ERROR in garbage stream: $error');
      },
    );
    print('✅ Listener set up successfully');
  }

  void _centerMapOnRoute() {
    if (widget.routePoints.isEmpty) return;

    // Calculate bounds to fit all route points
    double? minLat;
    double? maxLat;
    double? minLng;
    double? maxLng;

    for (var point in widget.routePoints) {
      if (minLat == null || point.latitude < minLat) minLat = point.latitude;
      if (maxLat == null || point.latitude > maxLat) maxLat = point.latitude;
      if (minLng == null || point.longitude < minLng) minLng = point.longitude;
      if (maxLng == null || point.longitude > maxLng) maxLng = point.longitude;
    }

    if (minLat == null || maxLat == null || minLng == null || maxLng == null)
      return;

    final center = LatLng(
      (minLat + maxLat) / 2,
      (minLng + maxLng) / 2,
    );

    // Delay to ensure map is ready
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _mapController.move(center, 14.0);
      }
    });
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

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );

      if (mounted) {
        setState(() {
          _currentLocation = LatLng(position.latitude, position.longitude);
          _initialPosition =
              _currentLocation; // Store initial position for 250m check
        });
      }

      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      );

      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen((Position position) {
        if (mounted) {
          setState(() {
            _currentLocation = LatLng(position.latitude, position.longitude);
            _updateNextGarbage(); // Update next garbage when location changes
          });

          // Check for auto-start after 250m
          if (_showStartButton && _initialPosition != null) {
            _checkAutoStartTracking();
          }

          _updateCollectorLocation(position.latitude, position.longitude);

          if (_isFollowing) {
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
        'activeRouteId': widget.routeId,
        'routeName': widget.routeName,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error updating collector location: $e');
    }
  }

  double _calculateDistanceToRoute(LatLng point) {
    if (widget.routePoints.isEmpty) return double.infinity;

    final Distance distance = Distance();
    double minDistance = double.infinity;

    for (int i = 0; i < widget.routePoints.length - 1; i++) {
      final start = widget.routePoints[i];
      final end = widget.routePoints[i + 1];
      final distanceToSegment =
          _pointToLineSegmentDistance(point, start, end, distance);

      if (distanceToSegment < minDistance) {
        minDistance = distanceToSegment;
      }
    }

    return minDistance;
  }

  double _pointToLineSegmentDistance(
      LatLng point, LatLng lineStart, LatLng lineEnd, Distance distance) {
    final distToStart = distance.as(LengthUnit.Meter, point, lineStart);
    final distToEnd = distance.as(LengthUnit.Meter, point, lineEnd);

    final segmentLength = distance.as(LengthUnit.Meter, lineStart, lineEnd);

    if (segmentLength == 0) return distToStart;

    final dx = lineEnd.longitude - lineStart.longitude;
    final dy = lineEnd.latitude - lineStart.latitude;
    final t = ((point.longitude - lineStart.longitude) * dx +
            (point.latitude - lineStart.latitude) * dy) /
        (dx * dx + dy * dy);

    if (t < 0) return distToStart;
    if (t > 1) return distToEnd;

    final projLat = lineStart.latitude + t * dy;
    final projLng = lineStart.longitude + t * dx;
    final projection = LatLng(projLat, projLng);

    return distance.as(LengthUnit.Meter, point, projection);
  }

  void _updateNextGarbage() {
    if (_garbageLocations.isEmpty) {
      _nextGarbage = null;
      return;
    }

    // Calculate distance from current location to each garbage
    const Distance distance = Distance();
    double minDistance = double.infinity;
    Map<String, dynamic>? nearest;

    for (var garbage in _garbageLocations) {
      final latValue = garbage['lat'];
      final lngValue = garbage['lng'];

      if (latValue == null || lngValue == null) continue;

      final garbageLocation = LatLng(
        latValue is double ? latValue : (latValue as num).toDouble(),
        lngValue is double ? lngValue : (lngValue as num).toDouble(),
      );
      final distanceInMeters = distance.as(
        LengthUnit.Meter,
        _currentLocation,
        garbageLocation,
      );

      if (distanceInMeters < minDistance) {
        minDistance = distanceInMeters;
        nearest = {
          ...garbage,
          'distanceFromCollector': distanceInMeters,
        };
      }
    }

    _nextGarbage = nearest;
  }

  Future<void> _checkAutoStartTracking() async {
    if (!_showStartButton || _initialPosition == null) return;

    const Distance distance = Distance();
    final distanceMeters = distance.as(
      LengthUnit.Meter,
      _initialPosition!,
      _currentLocation,
    );

    if (distanceMeters >= 250) {
      await _trackingService.startTracking();
      setState(() {
        _showStartButton = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tracking started automatically after 250m'),
            backgroundColor: Color(0xFF00A86B),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _loadGarbageAlongRoute() async {
    print('🔍 LOADING GARBAGE along route ${widget.routeId}...');
    setState(() => _isLoadingGarbage = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('❌ No user logged in');
        return;
      }

      // Get today's progress document to filter out collected bins
      final now = DateTime.now();
      final dateString =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final progressDocId = '${user.uid}_${widget.routeId}_$dateString';

      final progressDoc = await FirebaseFirestore.instance
          .collection('daily_route_progress')
          .doc(progressDocId)
          .get();

      Set<String> collectedBinIds = {};
      int previouslyCollected = 0;

      if (progressDoc.exists) {
        final progressData = progressDoc.data()!;
        collectedBinIds = Set<String>.from(progressData['collectedBins'] ?? []);
        previouslyCollected = collectedBinIds.length;
      }

      // Get garbage reports with status='pending' only
      final garbageSnapshot = await FirebaseFirestore.instance
          .collection('garbage_reports')
          .where('status', isEqualTo: 'pending')
          .get();

      // Filter by distance to route
      final garbageList = <Map<String, dynamic>>[];
      for (var doc in garbageSnapshot.docs) {
        final data = doc.data();
        final latValue = data['latitude'];
        final lngValue = data['longitude'];

        // Safely convert to double
        double? lat;
        double? lng;

        if (latValue != null) {
          if (latValue is double) {
            lat = latValue;
          } else if (latValue is int) {
            lat = latValue.toDouble();
          } else if (latValue is num) {
            lat = latValue.toDouble();
          }
        }

        if (lngValue != null) {
          if (lngValue is double) {
            lng = lngValue;
          } else if (lngValue is int) {
            lng = lngValue.toDouble();
          } else if (lngValue is num) {
            lng = lngValue.toDouble();
          }
        }

        if (lat != null && lng != null) {
          final binLocation = LatLng(lat, lng);
          final distanceToRoute = _calculateDistanceToRoute(binLocation);

          if (distanceToRoute <= 50) {
            // 50 meters from route
            garbageList.add({
              'id': doc.id,
              'lat': lat,
              'lng': lng,
              'latitude': lat,
              'longitude': lng,
              'address': data['address'] ?? 'Unknown location',
              'description': data['description'] ?? '',
              'imageUrl': data['imageUrl'],
              'reportedBy': data['reportedBy'],
              'status': data['status'],
            });
          }
        }
      }

      print('📍 FOUND ${garbageList.length} bins along route');
      print('✅ Previously collected: $previouslyCollected bins');

      // Filter out already collected bins
      final uncollectedGarbage = garbageList
          .where((garbage) => !collectedBinIds.contains(garbage['id']))
          .toList();

      print('🗑️ UNCOLLECTED BINS: ${uncollectedGarbage.length}');

      if (mounted) {
        setState(() {
          _garbageLocations = uncollectedGarbage;
          _totalGarbageCount = garbageList.length;
          _collectedCount = previouslyCollected;
          _isLoadingGarbage = false;
          _updateNextGarbage(); // Calculate next garbage
        });
      }
    } catch (e) {
      debugPrint('Error loading garbage: $e');
      if (mounted) {
        setState(() => _isLoadingGarbage = false);
      }
    }
  }

  Future<void> _markAsCollected(String garbageId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Check if session is active before allowing collection
      if (!_isSessionActive) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please start collecting session first'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Get garbage data before marking as collected
      final garbageDoc = await FirebaseFirestore.instance
          .collection('garbage_reports')
          .doc(garbageId)
          .get();

      if (!garbageDoc.exists) return;

      final garbageData = garbageDoc.data() as Map<String, dynamic>;
      final reportedBy = garbageData['reportedBy'] as String?;

      await FirebaseFirestore.instance
          .collection('garbage_reports')
          .doc(garbageId)
          .update({
        'status': 'collected',
        'collectorId': user.uid,
        'collectedAt': FieldValue.serverTimestamp(),
      });

      // Add to session service
      await _sessionService.addCollectedBin(garbageId);

      // Update daily progress document
      final now = DateTime.now();
      final dateString =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final progressDocId = '${user.uid}_${widget.routeId}_$dateString';

      await FirebaseFirestore.instance
          .collection('daily_route_progress')
          .doc(progressDocId)
          .set({
        'collectorId': user.uid,
        'routeId': widget.routeId,
        'routeName': widget.routeName,
        'date': dateString,
        'collectedBins': FieldValue.arrayUnion([garbageId]),
        'totalBins': _totalGarbageCount,
        'status': 'in_progress',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Send notification to the user who reported it
      if (reportedBy != null) {
        await FirebaseFirestore.instance.collection('notifications').add({
          'userId': reportedBy,
          'title': 'Garbage Collected!',
          'body':
              'Your reported garbage has been picked up by the collection team.',
          'type': 'garbage_collected',
          'garbageId': garbageId,
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
        });
      }

      if (mounted) {
        setState(() {
          _collectedCount++;
          _garbageLocations.removeWhere((item) => item['id'] == garbageId);
          _updateNextGarbage(); // Update next garbage after collection
        });

        // Calculate completion percentage
        final completionRate =
            (_collectedCount / _totalGarbageCount * 100).round();

        // Update completion rate in progress document
        await FirebaseFirestore.instance
            .collection('daily_route_progress')
            .doc(progressDocId)
            .update({
          'completionRate': completionRate.toDouble(),
          'status': completionRate >= 100 ? 'completed' : 'in_progress',
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Marked as collected! ($completionRate% complete)'),
            backgroundColor: const Color(0xFF00A86B),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to mark as collected: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showGarbageDetails(Map<String, dynamic> garbage) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(left: 20, right: 20, bottom: 20),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 400),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Top card section
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Trash icon at top
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              color: const Color(0xFF00A86B).withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.delete_rounded,
                              color: Color(0xFF00A86B),
                              size: 32,
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Title
                          const Text(
                            'Trash awaiting pickup...',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),

                          const SizedBox(height: 4),

                          // Trash ID
                          Text(
                            'Trash ID: ${garbage['id'].toString().length > 4 ? garbage['id'].toString().substring(garbage['id'].toString().length - 4) : garbage['id']}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // Location with icon
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.location_on,
                                  size: 18, color: Colors.grey[600]),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Location: ${garbage['address'] ?? 'No address'}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey[700],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Green info section
                    FutureBuilder<DocumentSnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('users')
                          .doc(garbage['userId'])
                          .get(),
                      builder: (context, userSnapshot) {
                        final userName =
                            userSnapshot.hasData && userSnapshot.data!.exists
                                ? (userSnapshot.data!.data()
                                        as Map<String, dynamic>)['fullName'] ??
                                    (userSnapshot.data!.data()
                                        as Map<String, dynamic>)['name'] ??
                                    (userSnapshot.data!.data()
                                        as Map<String, dynamic>)['firstName'] ??
                                    'Unknown User'
                                : 'Loading...';

                        // Get lat/lng - handle both formats
                        final lat = garbage['lat'] ??
                            garbage['coordinates']?['latitude'];
                        final lng = garbage['lng'] ??
                            garbage['coordinates']?['longitude'];

                        final garbageLocation = LatLng(
                          (lat is double ? lat : (lat as num).toDouble()),
                          (lng is double ? lng : (lng as num).toDouble()),
                        );

                        final distance = Geolocator.distanceBetween(
                          _currentLocation.latitude,
                          _currentLocation.longitude,
                          garbageLocation.latitude,
                          garbageLocation.longitude,
                        );

                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.symmetric(horizontal: 24),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00A86B).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.person_outline,
                                  size: 18, color: Color(0xFF00A86B)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'User:',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey[700],
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      userName,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 40,
                                color: Colors.grey[300],
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 12),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.near_me,
                                            size: 14, color: Color(0xFF00A86B)),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Distance:',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey[700],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${distance.toStringAsFixed(0)}m',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),

                    // Description
                    if (garbage['description'] != null &&
                        garbage['description'].toString().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.description,
                                    size: 16, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text(
                                  'Desc:',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey[700],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              garbage['description'],
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Buttons
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: Row(
                        children: [
                          // Back button
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                Navigator.pop(context);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey[300],
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                'Back',
                                style: TextStyle(
                                  color: Colors.grey[800],
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Pick Up button with 50m radius check
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () async {
                                // Check if collector is within 50m of the garbage
                                final lat = garbage['lat'] ??
                                    garbage['coordinates']?['latitude'];
                                final lng = garbage['lng'] ??
                                    garbage['coordinates']?['longitude'];

                                final garbageLocation = LatLng(
                                  (lat is double
                                      ? lat
                                      : (lat as num).toDouble()),
                                  (lng is double
                                      ? lng
                                      : (lng as num).toDouble()),
                                );

                                final distance = Geolocator.distanceBetween(
                                  _currentLocation.latitude,
                                  _currentLocation.longitude,
                                  garbageLocation.latitude,
                                  garbageLocation.longitude,
                                );

                                if (distance > 50) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          'You must be within 50m to mark as picked up. Current distance: ${distance.toStringAsFixed(0)}m'),
                                      backgroundColor: Colors.orange,
                                      duration: const Duration(seconds: 4),
                                    ),
                                  );
                                  return;
                                }

                                Navigator.pop(context);
                                _markAsCollected(garbage['id']);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00A86B),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Pick Up',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFinishDialog() async {
    if (_activeSessionId == null) return;

    // Get LIVE session data from Firestore
    final sessionDoc = await FirebaseFirestore.instance
        .collection('collector_sessions')
        .doc(_activeSessionId)
        .get();

    if (!sessionDoc.exists || !mounted) return;

    final sessionData = sessionDoc.data() as Map<String, dynamic>;

    // Calculate current distance and duration from session start
    final startTime =
        (sessionData['startTime'] as Timestamp?)?.toDate() ?? DateTime.now();
    final currentDuration = DateTime.now().difference(startTime);

    // Get current values from Firestore (live data)
    final distance =
        (sessionData['distanceTraveled'] as num?)?.toDouble() ?? 0.0;
    final binsCollected = (sessionData['binsCollected'] as num?)?.toInt() ?? 0;
    final missedBins = (sessionData['missedBins'] as List<dynamic>?) ?? [];

    print(
        '📊 FINISH DIALOG - Distance: ${distance}m, Duration: ${currentDuration.inSeconds}s, Bins: $binsCollected');

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Finish Collection Session'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Session Summary:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              _buildSummaryRow(
                Icons.route,
                'Distance',
                '${(distance / 1000).toStringAsFixed(2)} km',
              ),
              _buildSummaryRow(
                Icons.access_time,
                'Duration',
                '${(currentDuration.inSeconds / 60).toStringAsFixed(0)} min',
              ),
              _buildSummaryRow(
                Icons.delete,
                'Bins Collected',
                '$binsCollected',
              ),
              if (missedBins.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Missed Bins: ${missedBins.length}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 8),
                ...missedBins.take(3).map((bin) => Padding(
                      padding: const EdgeInsets.only(left: 16, bottom: 4),
                      child: Text(
                        '• ${bin['address'] ?? 'Unknown location'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    )),
                if (missedBins.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Text(
                      '...and ${missedBins.length - 3} more',
                      style: const TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A86B),
            ),
            child: const Text(
              'Finish Session',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // Stop timer
      _timer?.cancel();

      // Mark uncollected garbage as missed before finishing
      for (var garbage in _garbageLocations) {
        final binId = garbage['id'] as String;
        final address = garbage['address'] as String? ?? 'Unknown location';

        // Add to session's missed bins
        await _sessionService.addMissedBin(binId, address);

        // Update garbage report status to 'missed'
        await FirebaseFirestore.instance
            .collection('garbage_reports')
            .doc(binId)
            .update({
          'status': 'missed',
          'missedAt': FieldValue.serverTimestamp(),
          'collectorId': FirebaseAuth.instance.currentUser?.uid,
        });
      }

      // Finish session with total bins count and duration
      await _sessionService.finishSession(
        totalBins: _totalGarbageCount,
        duration: _elapsedTime,
      );
      await _trackingService.stopTracking();

      // Get final session data after finishing
      final finalSessionDoc = await FirebaseFirestore.instance
          .collection('collector_sessions')
          .doc(_activeSessionId)
          .get();

      // Notify users
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId != null && finalSessionDoc.exists) {
        final finalSessionData = finalSessionDoc.data() as Map<String, dynamic>;
        final collectedBins =
            (finalSessionData['collectedBins'] as List<dynamic>?) ?? [];
        final missedBins =
            (finalSessionData['missedBins'] as List<dynamic>?) ?? [];

        await UserNotificationService.notifyCollectorFinished(
          routeId: widget.routeId,
          routeName: widget.routeName,
          collectedBinIds: collectedBins.map((b) => b.toString()).toList(),
          missedBinIds: missedBins
              .map((b) => (b as Map<String, dynamic>)['binId'].toString())
              .toList(),
        );
      }

      setState(() {
        _isSessionActive = false;
        _activeSessionId = null;
        _showStartButton = true;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Collection session completed!'),
            backgroundColor: Color(0xFF00A86B),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Widget _buildSummaryRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF00A86B)),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          Text(value),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Active Route',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
            ),
            Text(
              widget.routeName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        centerTitle: false,
        leading: widget.showBackButton
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: widget.onBackPressed ?? () => Navigator.pop(context),
              )
            : null,
      ),
      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.routePoints.isNotEmpty
                  ? widget.routePoints.first
                  : _currentLocation,
              initialZoom: 14.0,
              onPositionChanged: (position, hasGesture) {
                if (hasGesture) {
                  setState(() => _isFollowing = false);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.binsync.app',
              ),
              // Route polyline (highlighted)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: widget.routePoints,
                    strokeWidth: 6.0,
                    color: const Color(0xFF00A86B),
                  ),
                ],
              ),
              // Markers
              MarkerLayer(
                markers: [
                  // Current location
                  Marker(
                    point: _currentLocation,
                    width: 50,
                    height: 50,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.navigation,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                  // Garbage markers
                  ..._garbageLocations.where((garbage) {
                    return garbage['lat'] != null && garbage['lng'] != null;
                  }).map((garbage) {
                    final latValue = garbage['lat'];
                    final lngValue = garbage['lng'];
                    final lat = latValue is double
                        ? latValue
                        : (latValue as num).toDouble();
                    final lng = lngValue is double
                        ? lngValue
                        : (lngValue as num).toDouble();

                    return Marker(
                      point: LatLng(lat, lng),
                      width: 50,
                      height: 50,
                      alignment: const Alignment(
                          0.15, -0.85), // Offset for pin tip position
                      child: GestureDetector(
                        onTap: _isSessionActive
                            ? () => _showGarbageDetails(garbage)
                            : null,
                        child: Image.asset(
                          'assets/images/garbage_pin.png',
                          width: 50,
                          height: 50,
                        ),
                      ),
                    );
                  }),
                  // Route start marker
                  if (widget.routePoints.isNotEmpty)
                    Marker(
                      point: widget.routePoints.first,
                      width: 40,
                      height: 40,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                        child: const Icon(
                          Icons.flag,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  // Route end marker
                  if (widget.routePoints.length > 1)
                    Marker(
                      point: widget.routePoints.last,
                      width: 40,
                      height: 40,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.orange,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                        child: const Icon(
                          Icons.stop,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),

          // Stats card
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Completion rate
                  if (_totalGarbageCount > 0) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Route Progress',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _collectedCount / _totalGarbageCount,
                                  backgroundColor: Colors.grey[200],
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    Color(0xFF00A86B),
                                  ),
                                  minHeight: 8,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${(_collectedCount / _totalGarbageCount * 100).round()}%',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF00A86B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatItem(
                        Icons.delete,
                        '${_garbageLocations.length}',
                        'Pending',
                        Colors.red,
                      ),
                      Container(
                        width: 1,
                        height: 40,
                        color: Colors.grey[300],
                      ),
                      _buildStatItem(
                        Icons.check_circle,
                        '$_collectedCount',
                        'Collected',
                        const Color(0xFF00A86B),
                      ),
                      Container(
                        width: 1,
                        height: 40,
                        color: Colors.grey[300],
                      ),
                      _buildStatItem(
                        Icons.access_time,
                        _formatDuration(_elapsedTime),
                        'Time',
                        Colors.blue,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Next Garbage Info Panel (Bottom)
          if (_nextGarbage != null && !_showStartButton)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Trash awaiting pickup',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Photo
                        if (_nextGarbage!['imageUrl'] != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              _nextGarbage!['imageUrl'],
                              width: 80,
                              height: 80,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  color: Colors.grey[300],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.image_not_supported),
                              ),
                            ),
                          )
                        else
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.delete, size: 40),
                          ),
                        const SizedBox(width: 12),
                        // Info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _nextGarbage!['issueType'] ?? 'Garbage',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.location_on,
                                    size: 14,
                                    color: Colors.grey,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      _nextGarbage!['address'] ??
                                          'Unknown location',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[600],
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.straighten,
                                    size: 14,
                                    color: Colors.grey,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${(_nextGarbage!['distanceFromCollector'] ?? 0).toStringAsFixed(0)}m away',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                              if (_nextGarbage!['description'] != null &&
                                  _nextGarbage!['description']
                                      .toString()
                                      .isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    _nextGarbage!['description'],
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => _markAsCollected(_nextGarbage!['id']),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A86B),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text(
                          'Collect',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Start Collecting Button
          if (_showStartButton)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Ready to start collecting?',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Track your distance and time automatically',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          setState(() {
                            _showStartButton = false;
                            _isSessionActive = true;
                            _initialPosition = _currentLocation;
                            _sessionStartTime = DateTime.now();
                            _startTimer();
                          });

                          // Start session in background
                          _sessionService
                              .startSession(
                            routeId: widget.routeId,
                            routeName: widget.routeName,
                          )
                              .then((sessionId) {
                            if (sessionId != null && mounted) {
                              setState(() => _activeSessionId = sessionId);
                            }
                          });

                          // Start tracking in background
                          _trackingService.startTracking();

                          // Notify users in background
                          final userId = FirebaseAuth.instance.currentUser?.uid;
                          if (userId != null) {
                            UserNotificationService.notifyCollectorStarted(
                              routeId: widget.routeId,
                              routeName: widget.routeName,
                              collectorId: userId,
                            );
                          }

                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Collection session started!'),
                                backgroundColor: Color(0xFF00A86B),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A86B),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'Start Collecting',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Or tracking will start automatically after 250m',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Finish Collecting Button (show when session is active)
          if (_isSessionActive && !_showStartButton)
            Positioned(
              bottom: _nextGarbage != null ? 220 : 20,
              left: 16,
              right: 16,
              child: ElevatedButton.icon(
                onPressed: () => _showFinishDialog(),
                icon: const Icon(Icons.stop_circle),
                label: const Text('Finish Collecting'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[600],
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

          // Follow location button
          Positioned(
            bottom: _showStartButton ? 280 : (_nextGarbage != null ? 220 : 80),
            right: 16,
            child: FloatingActionButton(
              heroTag: 'follow',
              onPressed: () {
                setState(() => _isFollowing = true);
                _mapController.move(_currentLocation, 16.0);
              },
              backgroundColor:
                  _isFollowing ? const Color(0xFF00A86B) : Colors.white,
              child: Icon(
                Icons.my_location,
                color: _isFollowing ? Colors.white : Colors.grey,
              ),
            ),
          ),

          // Loading indicator
          if (_isLoadingGarbage)
            Positioned(
              bottom: 16,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
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
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFF00A86B),
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Text('Loading garbage locations...'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
      IconData icon, String value, String label, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
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

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _sessionStartTime != null) {
        setState(() {
          _elapsedTime = DateTime.now().difference(_sessionStartTime!);
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }
}
