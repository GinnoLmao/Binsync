import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/route_service.dart';
import '../services/collector_tracking_service.dart';

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
    double minLat = widget.routePoints.first.latitude;
    double maxLat = widget.routePoints.first.latitude;
    double minLng = widget.routePoints.first.longitude;
    double maxLng = widget.routePoints.first.longitude;

    for (var point in widget.routePoints) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

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
      final garbageLocation = LatLng(garbage['lat'], garbage['lng']);
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

      final garbageList = await _routeService.getGarbageAlongRoute(
        routeId: widget.routeId,
        maxDistanceKm: 0.05, // 50 meters from route
      );

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
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
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
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.delete,
                    color: Color(0xFF00A86B),
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        garbage['issueType'] ?? 'Garbage Report',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        garbage['address'] ?? 'No address',
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
            const SizedBox(height: 16),
            if (garbage['description'] != null &&
                garbage['description'].toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Description:',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      garbage['description'],
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: Color(0xFF00A86B)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Close',
                      style: TextStyle(color: Color(0xFF00A86B)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _markAsCollected(garbage['id']);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A86B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Mark Collected'),
                  ),
                ),
              ],
            ),
          ],
        ),
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
      body: RefreshIndicator(
        onRefresh: () async {
          print('🔄 MANUAL REFRESH TRIGGERED');
          await _loadGarbageAlongRoute();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: MediaQuery.of(context).size.height,
            child: Stack(
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
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
                        ..._garbageLocations.map((garbage) {
                          return Marker(
                            point: LatLng(garbage['lat'], garbage['lng']),
                            width: 40,
                            height: 40,
                            child: GestureDetector(
                              onTap: () => _showGarbageDetails(garbage),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.white, width: 3),
                                ),
                                child: const Icon(
                                  Icons.delete,
                                  color: Colors.white,
                                  size: 20,
                                ),
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
                                border:
                                    Border.all(color: Colors.white, width: 3),
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
                                border:
                                    Border.all(color: Colors.white, width: 3),
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
                                        value: _collectedCount /
                                            _totalGarbageCount,
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
                              Icons.route,
                              '${widget.routePoints.length}',
                              'Points',
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
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            Container(
                                      width: 80,
                                      height: 80,
                                      decoration: BoxDecoration(
                                        color: Colors.grey[300],
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child:
                                          const Icon(Icons.image_not_supported),
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
                              onPressed: () =>
                                  _markAsCollected(_nextGarbage!['id']),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00A86B),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
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
                                await _trackingService.startTracking();
                                setState(() {
                                  _showStartButton = false;
                                  _initialPosition = _currentLocation;
                                });

                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Tracking started!'),
                                      backgroundColor: Color(0xFF00A86B),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00A86B),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
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

                // Follow location button
                Positioned(
                  bottom: _showStartButton
                      ? 280
                      : (_nextGarbage != null ? 220 : 80),
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
          ),
        ),
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
}
