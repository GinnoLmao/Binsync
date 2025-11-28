import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'collector_map_with_route_screen.dart';

class CollectorTrashListScreen extends StatefulWidget {
  const CollectorTrashListScreen({super.key});

  @override
  State<CollectorTrashListScreen> createState() =>
      _CollectorTrashListScreenState();
}

class _CollectorTrashListScreenState extends State<CollectorTrashListScreen> {
  @override
  void initState() {
    super.initState();
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

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.toStringAsFixed(0)} m';
    } else {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
  }

  String _formatTimestamp(Timestamp? timestamp) {
    if (timestamp == null) return 'Unknown';
    final date = timestamp.toDate();
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} mins';
    } else if (diff.inHours < 24) {
      return '${diff.inHours} hours';
    } else {
      return '${diff.inDays} days';
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: const Text(
          'Trash List',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: false,
      ),
      body: user == null
          ? const Center(child: Text('Please log in'))
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('collector_routes')
                  .where('collectorId', isEqualTo: user.uid)
                  .snapshots(),
              builder: (context, routeSnapshot) {
                if (routeSnapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final routes = routeSnapshot.data?.docs ?? [];

                if (routes.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.route,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No routes available',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                // Get active route
                QueryDocumentSnapshot activeRouteDoc;
                try {
                  activeRouteDoc = routes.firstWhere(
                    (doc) =>
                        (doc.data() as Map<String, dynamic>)['isActive'] ==
                        true,
                  );
                } catch (e) {
                  activeRouteDoc = routes.first;
                }

                final routeData = activeRouteDoc.data() as Map<String, dynamic>;
                final routePoints = (routeData['routePoints'] as List? ?? [])
                    .map((p) => LatLng(p['latitude'], p['longitude']))
                    .toList();

                if (routePoints.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Route has no points',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                // Load garbage along route
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('garbage_reports')
                      .where('status', isEqualTo: 'pending')
                      .snapshots(),
                  builder: (context, garbageSnapshot) {
                    if (garbageSnapshot.connectionState ==
                        ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final allGarbage = garbageSnapshot.data?.docs ?? [];
                    final garbageList = <Map<String, dynamic>>[];

                    // Filter garbage within 20m of route
                    for (var doc in allGarbage) {
                      final data = doc.data() as Map<String, dynamic>;
                      final garbageLat = data['latitude'] as double?;
                      final garbageLng = data['longitude'] as double?;

                      if (garbageLat == null || garbageLng == null) {
                        continue;
                      }

                      final garbagePoint = LatLng(garbageLat, garbageLng);
                      bool isNearRoute = false;
                      double minDistance = double.infinity;

                      // Check distance to each route segment
                      if (routePoints.length < 2) {
                        // If only 1 point, check direct distance
                        if (routePoints.isNotEmpty) {
                          minDistance = const Distance().as(
                              LengthUnit.Meter, garbagePoint, routePoints[0]);
                          isNearRoute = minDistance <= 50;
                        }
                      } else {
                        // Check all segments
                        for (int i = 0; i < routePoints.length - 1; i++) {
                          final segmentStart = routePoints[i];
                          final segmentEnd = routePoints[i + 1];
                          final distance = _distanceToLineSegment(
                              garbagePoint, segmentStart, segmentEnd);

                          if (distance < minDistance) {
                            minDistance = distance;
                          }
                          if (distance <= 50) {
                            isNearRoute = true;
                          }
                        }
                      }

                      if (isNearRoute) {
                        garbageList.add({
                          'id': doc.id,
                          'location': garbagePoint,
                          'address': data['address'] ?? 'Unknown location',
                          'reportedBy': data['reportedBy'] ?? 'Anonymous',
                          'timestamp': data['timestamp'],
                          'distance': minDistance,
                        });
                      }
                    }

                    // Sort by distance
                    garbageList
                        .sort((a, b) => a['distance'].compareTo(b['distance']));

                    if (garbageList.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.delete_outline,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No trash to collect',
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.grey[600],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'All trash on your route has been collected!',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[500],
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: () async {
                        print('🔄 TRASH LIST: Manual refresh triggered');
                        // StreamBuilder automatically updates, just add a small delay
                        await Future.delayed(const Duration(milliseconds: 300));
                      },
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: garbageList.length,
                        itemBuilder: (context, index) {
                          final garbage = garbageList[index];
                          return _buildTrashCard(
                            garbage,
                            index,
                            activeRouteDoc.id,
                            routeData['routeName'] ?? 'Route',
                            routePoints,
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _buildTrashCard(
    Map<String, dynamic> garbage,
    int index,
    String routeId,
    String routeName,
    List<LatLng> routePoints,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00A86B), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () {
          // Navigate to Collector Map and highlight this bin
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CollectorMapWithRouteScreen(
                routeId: routeId,
                routeName: routeName,
                routePoints: routePoints,
                showBackButton: true,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Checkmark icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF00A86B).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.check,
                  color: Color(0xFF00A86B),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Trash awaiting pick-up',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      garbage['address'],
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          'Trash ID: ${garbage['id'].substring(0, 8)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 3,
                          height: 3,
                          decoration: BoxDecoration(
                            color: Colors.grey[400],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatTimestamp(garbage['timestamp']),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatDistance(garbage['distance']),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF00A86B),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Colors.grey,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
