import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async';
import '../services/auth_service.dart';
import '../services/route_service.dart';
import '../services/collector_tracking_service.dart';
import '../services/collector_session_service.dart';
import 'collector_map_with_route_screen.dart';
import 'collector_stats_screen.dart';
import 'collector_settings_screen.dart';
import 'collector_profile_screen.dart';
import 'collector_report_bug_screen.dart';
import 'user_agreement_screen.dart';
import 'about_us_screen.dart';
import 'route_creator_screen.dart';
import 'route_recorder_screen.dart';

class CollectorHomeScreen extends StatefulWidget {
  final VoidCallback? onNavigateToMap;
  final VoidCallback? onNavigateToStats;

  const CollectorHomeScreen(
      {super.key, this.onNavigateToMap, this.onNavigateToStats});

  @override
  State<CollectorHomeScreen> createState() => _CollectorHomeScreenState();
}

class _CollectorHomeScreenState extends State<CollectorHomeScreen> {
  final RouteService _routeService = RouteService();
  final CollectorTrackingService _trackingService = CollectorTrackingService();
  final CollectorSessionService _sessionService = CollectorSessionService();
  String? _activeRouteId;
  String? _activeRouteName;
  List<LatLng>? _activeRoutePoints;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _refreshTimer;

  // Tracking data
  double _todayDistance = 0.0;
  Duration _todayDuration = Duration.zero;
  double _completionRate = 0.0;
  int _collectedCount = 0;
  int _totalCount = 0;
  double _efficiency = 0.0;

  @override
  void initState() {
    super.initState();
    _loadActiveRoute(); // This will call _loadTodayData() after route is loaded

    // Start timer to refresh UI every second if session is active
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _sessionService.isSessionActive) {
        setState(() {});
      }
    });

    // Listen for tracking updates
    _trackingService.onUpdate = (distance, duration) {
      setState(() {
        _todayDistance = distance;
        _todayDuration = duration;
      });
    };
  }

  Future<void> _loadActiveRoute() async {
    final route = await _routeService.getActiveRoute();
    if (route != null && mounted) {
      setState(() {
        _activeRouteId = route['id'];
        _activeRouteName = route['name'];
        _activeRoutePoints = (route['points'] as List)
            .map((p) => LatLng(p['latitude'], p['longitude']))
            .toList();
      });
      // Reload data after route is loaded
      _loadTodayData();
    }
  }

  Future<void> _loadTodayData() async {
    final data = await _trackingService.getTodayTrackingData();

    // Get collected bins for today
    final userId = FirebaseAuth.instance.currentUser?.uid;
    int collected = 0;
    int total = 0;

    if (userId != null &&
        _activeRouteId != null &&
        _activeRoutePoints != null) {
      // Get progress document to see how many were collected
      final progressDocId = _getProgressDocId(_activeRouteId!);
      final progressDoc = await FirebaseFirestore.instance
          .collection('daily_route_progress')
          .doc(progressDocId)
          .get();

      if (progressDoc.exists) {
        final progressData = progressDoc.data()!;
        final collectedBins =
            List<String>.from(progressData['collectedBins'] ?? []);
        collected = collectedBins.length;
      } else {
        collected = 0;
      }

      // Get current pending garbage count (same logic as trash list)
      final allBins = await FirebaseFirestore.instance
          .collection('garbage_reports')
          .where('status', isEqualTo: 'pending')
          .get();

      int pendingCount = 0;
      for (var doc in allBins.docs) {
        final data = doc.data();
        final garbageLat = data['latitude'] as double?;
        final garbageLng = data['longitude'] as double?;

        if (garbageLat == null || garbageLng == null) continue;

        final garbagePoint = LatLng(garbageLat, garbageLng);
        bool isNearRoute = false;

        // Check if garbage is within 50m of any route segment
        for (int i = 0; i < _activeRoutePoints!.length - 1; i++) {
          final distance = _distanceToLineSegment(
            garbagePoint,
            _activeRoutePoints![i],
            _activeRoutePoints![i + 1],
          );

          if (distance <= 50) {
            isNearRoute = true;
            break;
          }
        }

        if (isNearRoute) {
          pendingCount++;
        }
      }

      // Total = pending bins + collected bins today
      total = pendingCount + collected;
    }

    // Calculate completion rate
    final completionRate = total > 0 ? (collected / total * 100) : 0.0;

    // Calculate efficiency
    final distance = data['distance'] ?? 0.0;
    final duration = data['duration'] ?? Duration.zero;
    final hours = duration.inSeconds / 3600.0;
    final km = distance / 1000.0;

    double efficiency = 0.0;
    if (collected > 0 && hours > 0 && km > 0) {
      final binsPerHour = collected / hours;
      final binsPerKm = collected / km;

      // Target: 10 bins/hour and 5 bins/km
      final e1 = binsPerHour / 10.0;
      final e2 = binsPerKm / 5.0;

      efficiency = ((e1 + e2) / 2.0 * 100).clamp(0.0, 100.0);
    }

    setState(() {
      _todayDistance = distance;
      _todayDuration = duration;
      _completionRate = completionRate;
      _collectedCount = collected;
      _totalCount = total;
      _efficiency = efficiency;
    });
  }

  String _getTodayDateString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _getProgressDocId(String routeId) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return '';
    return '${user.uid}_${routeId}_${_getTodayDateString()}';
  }

  double _distanceToLineSegment(
      LatLng point, LatLng lineStart, LatLng lineEnd) {
    const Distance distanceCalc = Distance();

    // If start and end are the same point
    if (lineStart.latitude == lineEnd.latitude &&
        lineStart.longitude == lineEnd.longitude) {
      return distanceCalc.as(LengthUnit.Meter, point, lineStart);
    }

    // Calculate perpendicular distance
    final distToStart = distanceCalc.as(LengthUnit.Meter, point, lineStart);
    final segmentLength = distanceCalc.as(LengthUnit.Meter, lineStart, lineEnd);

    // Check if projection falls on the segment
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

  @override
  void didUpdateWidget(CollectorHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload data when widget updates (e.g., returning from map)
    _loadTodayData();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _trackingService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFF5F5F5),
      drawer: _buildDrawer(context, authService, user),
      body: SafeArea(
        child: Column(
          children: [
            // Top Header with menu and user info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF00A86B),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.menu, color: Colors.white),
                        onPressed: () {
                          _scaffoldKey.currentState?.openDrawer();
                        },
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FutureBuilder<DocumentSnapshot>(
                              future: FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(user?.uid)
                                  .get(),
                              builder: (context, snapshot) {
                                final userData = snapshot.data?.data()
                                    as Map<String, dynamic>?;
                                final name = userData?['fullName'] ??
                                    user?.email?.split('@')[0] ??
                                    'John Doe';
                                return Text(
                                  name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                );
                              },
                            ),
                            Text(
                              'Truck ID: ${user?.uid.substring(0, 8).toUpperCase() ?? '0001'}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Today's Progress Card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Today\'s Progress',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${_completionRate.toInt()}% Complete',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              '$_collectedCount/$_totalCount Bins',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: _completionRate / 100,
                            backgroundColor: Colors.white.withOpacity(0.3),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.white),
                            minHeight: 8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Body Content
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  print('🔄 HOME SCREEN: Manual refresh triggered');
                  await _loadTodayData();
                  await _loadActiveRoute();
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Statistics Cards - Direct from Session Service
                      Row(
                        children: [
                          Expanded(
                            child: _buildStatCard(
                              Icons.straighten,
                              'Distance',
                              '${(_sessionService.totalDistance / 1000).toStringAsFixed(1)}km',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildStatCard(
                              Icons.access_time,
                              'Hours',
                              _formatDuration(_sessionService.sessionDuration),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildStatCard(
                              Icons.trending_up,
                              'Efficiency',
                              '${_calculateEfficiency()}%',
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // Today's Route Section with Route Selector
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Today\'s Route',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          if (_activeRouteName != null)
                            Row(
                              children: [
                                Text(
                                  _activeRouteName!,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed: () {
                                    _showRouteSelector(context);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00A86B),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: const Text(
                                    'Change',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Route List
                      StreamBuilder<QuerySnapshot>(
                        stream: _routeService.getCollectorRoutes(),
                        builder: (context, routeSnapshot) {
                          final routes = routeSnapshot.data?.docs ?? [];

                          if (routes.isEmpty) {
                            return _buildNoRouteCard();
                          }

                          // Get active route (where isActive == true)
                          QueryDocumentSnapshot activeRouteDoc;
                          try {
                            activeRouteDoc = routes.firstWhere(
                              (doc) =>
                                  (doc.data()
                                      as Map<String, dynamic>)['isActive'] ==
                                  true,
                            );
                          } catch (e) {
                            // If no active route found, use first route
                            activeRouteDoc = routes.first;
                          }
                          final routeData =
                              activeRouteDoc.data() as Map<String, dynamic>;
                          final routeName =
                              routeData['routeName'] ?? 'Unnamed Route';
                          final routePoints = (routeData['routePoints']
                                      as List? ??
                                  [])
                              .map((p) => LatLng(p['latitude'], p['longitude']))
                              .toList();

                          // Update active route state
                          if (_activeRouteId != activeRouteDoc.id) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              setState(() {
                                _activeRouteId = activeRouteDoc.id;
                                _activeRouteName = routeName;
                                _activeRoutePoints = routePoints;
                              });
                            });
                          }

                          // Use StreamBuilder for real-time updates of garbage
                          return StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('garbage_reports')
                                .where('status', isEqualTo: 'pending')
                                .snapshots(),
                            builder: (context, allGarbageSnapshot) {
                              if (allGarbageSnapshot.connectionState ==
                                  ConnectionState.waiting) {
                                return const Center(
                                    child: CircularProgressIndicator());
                              }

                              // Filter garbage within 30m of route
                              final allGarbage =
                                  allGarbageSnapshot.data?.docs ?? [];
                              final routeGarbage = <Map<String, dynamic>>[];

                              for (var doc in allGarbage) {
                                final data = doc.data() as Map<String, dynamic>;
                                final garbageLat = data['latitude'] as double?;
                                final garbageLng = data['longitude'] as double?;

                                if (garbageLat == null || garbageLng == null) {
                                  continue;
                                }

                                final garbagePoint =
                                    LatLng(garbageLat, garbageLng);
                                bool isNearRoute = false;

                                // Check distance to route
                                for (int i = 0;
                                    i < routePoints.length - 1;
                                    i++) {
                                  final distance = _distanceToLineSegment(
                                    garbagePoint,
                                    routePoints[i],
                                    routePoints[i + 1],
                                  );

                                  if (distance <= 50) {
                                    // 50 meters
                                    isNearRoute = true;
                                    break;
                                  }
                                }

                                if (isNearRoute) {
                                  routeGarbage.add({
                                    'id': doc.id,
                                    'lat': garbageLat,
                                    'lng': garbageLng,
                                    'address': data['address'] ?? 'Unknown',
                                    'issueType': data['issueType'] ?? 'Unknown',
                                    'description': data['description'] ?? '',
                                    'timestamp': data['timestamp'],
                                  });
                                }
                              }

                              if (routeGarbage.isEmpty) {
                                return _buildNoGarbageCard();
                              }

                              // Show first 3 items
                              final displayCount = routeGarbage.length > 3
                                  ? 3
                                  : routeGarbage.length;

                              return Column(
                                children: [
                                  ListView.builder(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    itemCount: displayCount,
                                    itemBuilder: (context, index) {
                                      final garbage = routeGarbage[index];
                                      return InkWell(
                                        onTap: () {
                                          // Navigate to Collector Map with this bin
                                          if (_activeRoutePoints != null) {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    CollectorMapWithRouteScreen(
                                                  routeId: _activeRouteId!,
                                                  routeName: _activeRouteName ??
                                                      'Route',
                                                  routePoints:
                                                      _activeRoutePoints!,
                                                  showBackButton: true,
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                        child: _buildTrashItem(
                                            garbage, routePoints),
                                      );
                                    },
                                  ),
                                  if (routeGarbage.length > 3)
                                    TextButton(
                                      onPressed: () {
                                        // Navigate to Collector Trash List to see all
                                        if (_activeRoutePoints != null) {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  CollectorMapWithRouteScreen(
                                                routeId: _activeRouteId!,
                                                routeName:
                                                    _activeRouteName ?? 'Route',
                                                routePoints:
                                                    _activeRoutePoints!,
                                                showBackButton: true,
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                      child: const Text(
                                        'View More',
                                        style: TextStyle(
                                          color: Color(0xFF00A86B),
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          );
                        },
                      ),

                      const SizedBox(height: 24),

                      // Quick Actions Section
                      const Text(
                        'Quick Actions',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),

                      const SizedBox(height: 12),

                      // View Performance Button
                      _buildActionButton(
                        icon: Icons.trending_up,
                        label: 'View Performance',
                        color: Colors.white,
                        textColor: Colors.black87,
                        onTap: () {
                          if (widget.onNavigateToStats != null) {
                            widget.onNavigateToStats!();
                          }
                        },
                      ),

                      const SizedBox(height: 12),

                      // View Route Map Button
                      _buildActionButton(
                        icon: Icons.map,
                        label: 'View Route Map',
                        color: const Color(0xFF00A86B),
                        textColor: Colors.white,
                        onTap: () {
                          if (widget.onNavigateToMap != null) {
                            widget.onNavigateToMap!();
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Please select a route first')),
                            );
                          }
                        },
                      ),

                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFF00A86B), size: 32),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrashItem(
      Map<String, dynamic> garbage, List<LatLng> routePoints) {
    final distance = garbage['distanceFromCollector'] ?? 0.0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF00A86B).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.delete,
              color: Color(0xFF00A86B),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Trash ID: ${garbage['id']?.substring(0, 8) ?? '0001'}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  garbage['address'] ?? 'Unknown location',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text(
                      'ETA: 15mins',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Distance: ${(distance).toStringAsFixed(1)}km',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _buildNoRouteCard() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.route, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              'No routes available',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoGarbageCard() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.check_circle, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              'No trash on this route',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: color == Colors.white
              ? Border.all(color: Colors.grey[300]!)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: textColor, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    if (hours > 0) {
      return '$hours.${(minutes / 60 * 10).toInt()}hrs';
    }
    return '${minutes}mins';
  }

  int _calculateEfficiency() {
    final duration = _sessionService.sessionDuration;
    final distance = _sessionService.totalDistance;
    final hours = duration.inSeconds / 3600.0;
    final km = distance / 1000.0;

    if (_sessionService.binsCollected > 0 && hours > 0 && km > 0) {
      final binsPerHour = _sessionService.binsCollected / hours;
      final binsPerKm = _sessionService.binsCollected / km;
      final e1 = binsPerHour / 10.0;
      final e2 = binsPerKm / 5.0;
      return (((e1 + e2) / 2.0 * 100).clamp(0.0, 100.0)).toInt();
    }
    return 0;
  }

  Stream<DocumentSnapshot> _getTodayTrackingStream() {
    final user = FirebaseAuth.instance.currentUser;
    final today = DateTime.now();
    final dateStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final docId = '${user?.uid}_$dateStr';

    return FirebaseFirestore.instance
        .collection('tracking_sessions')
        .doc(docId)
        .snapshots();
  }

  Widget _buildDrawer(
      BuildContext context, AuthService authService, User? user) {
    return Drawer(
      child: Container(
        color: const Color(0xFFF5F5F5),
        child: Column(
          children: [
            // Drawer Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
              decoration: const BoxDecoration(
                color: Color(0xFF00A86B),
              ),
              child: Column(
                children: [
                  StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('users')
                        .doc(user?.uid)
                        .snapshots(),
                    builder: (context, snapshot) {
                      final userData =
                          snapshot.data?.data() as Map<String, dynamic>?;
                      final name = userData?['fullName'] ??
                          user?.email?.split('@')[0] ??
                          'John Doe';
                      final initials = name
                          .split(' ')
                          .map((n) => n[0])
                          .take(2)
                          .join()
                          .toUpperCase();

                      return Column(
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                            child: Center(
                              child: Text(
                                initials,
                                style: const TextStyle(
                                  color: Color(0xFF00A86B),
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'MEMBER',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),

            // Menu Items
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _buildDrawerItem(
                    context,
                    icon: Icons.add_road,
                    title: 'Create Route',
                    onTap: () {
                      Navigator.pop(context);
                      _showRouteOptions();
                    },
                  ),
                  _buildDrawerItem(
                    context,
                    icon: Icons.settings,
                    title: 'Settings',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const CollectorSettingsScreen(),
                        ),
                      );
                    },
                  ),
                  _buildDrawerItem(
                    context,
                    icon: Icons.edit,
                    title: 'Profile',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const CollectorProfileScreen(),
                        ),
                      );
                    },
                  ),
                  _buildDrawerItem(
                    context,
                    icon: Icons.description,
                    title: 'Report',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const CollectorReportBugScreen(),
                        ),
                      );
                    },
                  ),
                  _buildDrawerItem(
                    context,
                    icon: Icons.article,
                    title: 'User Agreement',
                    onTap: () {
                      Navigator.pop(context);
                      showDialog(
                        context: context,
                        builder: (context) => const UserAgreementScreen(),
                      );
                    },
                  ),
                  _buildDrawerItem(
                    context,
                    icon: Icons.book,
                    title: 'About us',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const AboutUsScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            // Logout Button at Bottom
            Container(
              padding: const EdgeInsets.all(16),
              child: ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text(
                  'Logout',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await authService.signOut();
                },
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),

            // Footer
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '© 2025 - BinSync All rights reserved',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: Colors.black87),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: onTap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  void _showRouteSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(20),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF00A86B).withOpacity(0.1),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Select Route',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: StreamBuilder<QuerySnapshot>(
                stream: _routeService.getCollectorRoutes(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32.0),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }

                  final routes = snapshot.data?.docs ?? [];

                  if (routes.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32.0),
                        child: Text('No routes available'),
                      ),
                    );
                  }

                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: routes.length,
                    padding: const EdgeInsets.all(16),
                    itemBuilder: (context, index) {
                      final route = routes[index];
                      final routeData = route.data() as Map<String, dynamic>;
                      final routeName =
                          routeData['routeName'] ?? 'Unnamed Route';
                      final routePoints =
                          (routeData['routePoints'] as List? ?? [])
                              .map((p) => LatLng(p['latitude'], p['longitude']))
                              .toList();
                      final isActive = _activeRouteId == route.id;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFF00A86B).withOpacity(0.1)
                              : Colors.grey[100],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isActive
                                ? const Color(0xFF00A86B)
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? const Color(0xFF00A86B)
                                  : Colors.grey[400],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.route,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            routeName,
                            style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            '${routePoints.length} points',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                          trailing: isActive
                              ? const Icon(
                                  Icons.check_circle,
                                  color: Color(0xFF00A86B),
                                )
                              : const Icon(Icons.chevron_right),
                          onTap: () async {
                            // Update active route in Firestore
                            try {
                              final user = FirebaseAuth.instance.currentUser;
                              if (user != null) {
                                // Deactivate all routes for this collector
                                final allRoutes = await FirebaseFirestore
                                    .instance
                                    .collection('collector_routes')
                                    .where('collectorId', isEqualTo: user.uid)
                                    .get();

                                for (var doc in allRoutes.docs) {
                                  await doc.reference
                                      .update({'isActive': false});
                                }

                                // Activate selected route
                                await FirebaseFirestore.instance
                                    .collection('collector_routes')
                                    .doc(route.id)
                                    .update({
                                  'isActive': true,
                                  'lastUsed': FieldValue.serverTimestamp(),
                                });
                              }
                            } catch (e) {
                              print('Error updating active route: $e');
                            }

                            setState(() {
                              _activeRouteId = route.id;
                              _activeRouteName = routeName;
                              _activeRoutePoints = routePoints;
                            });
                            Navigator.pop(context);
                            _loadTodayData(); // Refresh data
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRouteOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Create New Route',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            _buildRouteOptionButton(
              icon: Icons.touch_app,
              title: 'Manual Route',
              subtitle: 'Tap on streets to create a route',
              color: const Color(0xFF00A86B),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RouteCreatorScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildRouteOptionButton(
              icon: Icons.radio_button_checked,
              title: 'Record Route',
              subtitle: 'Drive and record your route in real-time',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RouteRecorderScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteOptionButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 20, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }
}
