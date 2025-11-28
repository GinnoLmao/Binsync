import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/route_service.dart';
import 'route_creator_screen.dart';
import 'route_recorder_screen.dart';
import 'collector_map_with_route_screen.dart';
import 'package:latlong2/latlong.dart';

class RouteListScreen extends StatefulWidget {
  const RouteListScreen({super.key});

  @override
  State<RouteListScreen> createState() => _RouteListScreenState();
}

class _RouteListScreenState extends State<RouteListScreen> {
  final RouteService _routeService = RouteService();
  Set<String> _pinnedRoutes = {};

  @override
  void initState() {
    super.initState();
    _loadPinnedRoutes();
  }

  Future<void> _loadPinnedRoutes() async {
    final userId = await _routeService.getCurrentUserId();
    if (userId != null) {
      final doc = await FirebaseFirestore.instance
          .collection('user_preferences')
          .doc(userId)
          .get();
      if (doc.exists) {
        final data = doc.data();
        setState(() {
          _pinnedRoutes = Set<String>.from(data?['pinnedRoutes'] ?? []);
        });
      }
    }
  }

  Future<void> _togglePin(String routeId) async {
    if (_pinnedRoutes.contains(routeId)) {
      setState(() {
        _pinnedRoutes.remove(routeId);
      });
    } else {
      if (_pinnedRoutes.length >= 3) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You can only pin up to 3 routes'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      setState(() {
        _pinnedRoutes.add(routeId);
      });
    }

    final userId = await _routeService.getCurrentUserId();
    if (userId != null) {
      await FirebaseFirestore.instance
          .collection('user_preferences')
          .doc(userId)
          .set({
        'pinnedRoutes': _pinnedRoutes.toList(),
      }, SetOptions(merge: true));
    }
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
            _buildOptionButton(
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
            _buildOptionButton(
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

  Widget _buildOptionButton({
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

  Future<void> _deleteRoute(String routeId, String routeName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Route'),
        content: Text('Are you sure you want to delete "$routeName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _routeService.deleteRoute(routeId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Route deleted successfully'),
              backgroundColor: Color(0xFF00A86B),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete route: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _selectRoute(Map<String, dynamic> routeData, String routeId) async {
    try {
      // Mark route as used
      await _routeService.markRouteAsUsed(routeId);

      // Parse route points
      final routePoints = (routeData['routePoints'] as List)
          .map((point) => LatLng(
                point['latitude'] as double,
                point['longitude'] as double,
              ))
          .toList();

      if (mounted) {
        // Navigate to map with selected route
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CollectorMapWithRouteScreen(
              routeId: routeId,
              routeName: routeData['routeName'],
              routePoints: routePoints,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load route: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
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
          'My Routes',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: false,
        automaticallyImplyLeading: false,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _routeService.getCollectorRoutes(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final routes = snapshot.data?.docs ?? [];

          // Separate pinned and unpinned routes
          final pinnedRoutesList =
              routes.where((doc) => _pinnedRoutes.contains(doc.id)).toList();
          final unpinnedRoutesList =
              routes.where((doc) => !_pinnedRoutes.contains(doc.id)).toList();

          // Sort both lists alphabetically by route name
          pinnedRoutesList.sort((a, b) {
            final aData = a.data() as Map<String, dynamic>;
            final bData = b.data() as Map<String, dynamic>;
            final aName = (aData['routeName'] ?? 'Unnamed Route')
                .toString()
                .toLowerCase();
            final bName = (bData['routeName'] ?? 'Unnamed Route')
                .toString()
                .toLowerCase();
            return aName.compareTo(bName);
          });

          unpinnedRoutesList.sort((a, b) {
            final aData = a.data() as Map<String, dynamic>;
            final bData = b.data() as Map<String, dynamic>;
            final aName = (aData['routeName'] ?? 'Unnamed Route')
                .toString()
                .toLowerCase();
            final bName = (bData['routeName'] ?? 'Unnamed Route')
                .toString()
                .toLowerCase();
            return aName.compareTo(bName);
          });

          // Combine: pinned routes first, then unpinned
          final sortedRoutes = [...pinnedRoutesList, ...unpinnedRoutesList];

          if (sortedRoutes.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.route,
                    size: 80,
                    color: Colors.grey[300],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No routes yet',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create your first collection route',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey[500],
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _showRouteOptions,
                    icon: const Icon(Icons.add),
                    label: const Text('Create Route'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A86B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: sortedRoutes.length,
                  itemBuilder: (context, index) {
                    final doc = sortedRoutes[index];
                    final routeData = doc.data() as Map<String, dynamic>;
                    final routeName = routeData['routeName'] ?? 'Unnamed Route';
                    final description = routeData['description'] ?? '';
                    final routePoints = routeData['routePoints'] as List? ?? [];
                    final lastUsed = routeData['lastUsed'] as Timestamp?;
                    final isPinned = _pinnedRoutes.contains(doc.id);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: InkWell(
                        onTap: () => _selectRoute(routeData, doc.id),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Stack(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF00A86B)
                                          .withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(
                                      Icons.route,
                                      color: Color(0xFF00A86B),
                                      size: 28,
                                    ),
                                  ),
                                  if (isPinned)
                                    Positioned(
                                      top: 0,
                                      right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.all(3),
                                        decoration: const BoxDecoration(
                                          color: Colors.amber,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.push_pin,
                                          size: 12,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      routeName,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    if (description.isNotEmpty)
                                      Text(
                                        description,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.grey[600],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${routePoints.length} points',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[500],
                                      ),
                                    ),
                                    if (lastUsed != null)
                                      Text(
                                        'Last used: ${_formatTimestamp(lastUsed)}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'delete') {
                                    _deleteRoute(doc.id, routeName);
                                  } else if (value == 'pin') {
                                    _togglePin(doc.id);
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'pin',
                                    child: Row(
                                      children: [
                                        Icon(
                                          isPinned
                                              ? Icons.push_pin_outlined
                                              : Icons.push_pin,
                                          color: Colors.amber,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(isPinned ? 'Unpin' : 'Pin to top'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Delete'),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showRouteOptions,
        backgroundColor: const Color(0xFF00A86B),
        icon: const Icon(Icons.add),
        label: const Text('New Route'),
      ),
    );
  }

  String _formatTimestamp(Timestamp timestamp) {
    final date = timestamp.toDate();
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'Today';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
