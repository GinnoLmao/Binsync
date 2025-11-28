import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/firestore_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _firestoreService = FirestoreService();
  final _descriptionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  String? _selectedIssue;
  String _locationText = 'Getting location...';
  Position? _currentPosition; // This will be the snapped position
  Position? _originalPosition; // User's actual GPS location
  File? _imageFile;
  bool _isSubmitting = false;
  String? _selectedActivityId;
  bool _wasSnapped = false; // Track if location was snapped

  final List<Map<String, dynamic>> _issueTypes = [
    {
      'id': 'missed_bin',
      'label': 'Missed Bin',
      'icon': Icons.delete_outline,
      'color': Colors.red
    },
    {
      'id': 'damaged_bin',
      'label': 'Damaged Bin',
      'icon': Icons.warning_amber,
      'color': Colors.orange
    },
    {
      'id': 'misplaced_waste',
      'label': 'Misplaced Waste',
      'icon': Icons.recycling,
      'color': Colors.blue
    },
    {
      'id': 'other_issues',
      'label': 'Other Issues',
      'icon': Icons.more_horiz,
      'color': Colors.grey
    },
  ];

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    try {
      // Location permission already handled in user_map_screen
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          _locationText = 'Location permission denied';
        });
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Store original position
      _originalPosition = position;

      // Snap location to nearest road/route
      final snappedPosition = await _snapToNearestRoad(position);

      // Check if position was actually snapped to a collector route
      final snappedToRoute = await _checkIfNearCollectorRoute(snappedPosition);

      // Check if position was actually snapped
      final distanceFromOriginal = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        snappedPosition.latitude,
        snappedPosition.longitude,
      );

      _wasSnapped = distanceFromOriginal > 5; // Snapped if moved more than 5m

      List<Placemark> placemarks = await placemarkFromCoordinates(
        snappedPosition.latitude,
        snappedPosition.longitude,
      );

      if (placemarks.isNotEmpty) {
        Placemark place = placemarks[0];
        setState(() {
          _currentPosition = snappedPosition;
          _locationText =
              '${place.street ?? ''}, ${place.locality ?? ''}, ${place.subAdministrativeArea ?? ''}';
        });
      }
    } catch (e) {
      setState(() {
        _locationText = 'Failed to get location';
      });
    }
  }

  Future<Position> _snapToNearestRoad(Position position) async {
    try {
      // First, try to snap to nearest collector route
      final snappedToRoute = await _snapToNearestCollectorRoute(position);
      if (snappedToRoute != null) {
        print('✅ Snapped to collector route');
        return snappedToRoute;
      }

      // Fallback: Use OSRM nearest API to snap to nearest road
      final url =
          'https://router.project-osrm.org/nearest/v1/driving/${position.longitude},${position.latitude}';

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 'Ok' &&
            data['waypoints'] != null &&
            data['waypoints'].isNotEmpty) {
          final snappedLocation = data['waypoints'][0]['location'];
          final snappedLng = snappedLocation[0] as double;
          final snappedLat = snappedLocation[1] as double;

          // Return snapped position
          return Position(
            latitude: snappedLat,
            longitude: snappedLng,
            timestamp: position.timestamp,
            accuracy: position.accuracy,
            altitude: position.altitude,
            heading: position.heading,
            speed: position.speed,
            speedAccuracy: position.speedAccuracy,
            altitudeAccuracy: position.altitudeAccuracy,
            headingAccuracy: position.headingAccuracy,
          );
        }
      }
    } catch (e) {
      debugPrint('Error snapping to road: $e');
    }

    // Return original position if snapping fails
    return position;
  }

  Future<Position?> _snapToNearestCollectorRoute(Position position) async {
    try {
      // Get all collector routes
      final routesSnapshot =
          await FirebaseFirestore.instance.collection('collector_routes').get();

      if (routesSnapshot.docs.isEmpty) return null;

      Position? nearestPoint;
      double minDistance = double.infinity;
      const Distance distanceCalc = Distance();

      // Check all routes
      for (var routeDoc in routesSnapshot.docs) {
        final routeData = routeDoc.data();
        final routePoints = (routeData['routePoints'] as List?)
            ?.map((p) =>
                LatLng(p['latitude'] as double, p['longitude'] as double))
            .toList();

        if (routePoints == null || routePoints.isEmpty) continue;

        final userPoint = LatLng(position.latitude, position.longitude);

        // Find nearest point on this route
        for (int i = 0; i < routePoints.length - 1; i++) {
          final segmentStart = routePoints[i];
          final segmentEnd = routePoints[i + 1];

          // Find closest point on line segment
          final closestPoint =
              _getClosestPointOnSegment(userPoint, segmentStart, segmentEnd);
          final distance =
              distanceCalc.as(LengthUnit.Meter, userPoint, closestPoint);

          if (distance < minDistance && distance <= 35) {
            // Within 35m
            minDistance = distance;
            nearestPoint = Position(
              latitude: closestPoint.latitude,
              longitude: closestPoint.longitude,
              timestamp: position.timestamp,
              accuracy: position.accuracy,
              altitude: position.altitude,
              heading: position.heading,
              speed: position.speed,
              speedAccuracy: position.speedAccuracy,
              altitudeAccuracy: position.altitudeAccuracy,
              headingAccuracy: position.headingAccuracy,
            );
          }
        }
      }

      return nearestPoint;
    } catch (e) {
      debugPrint('Error snapping to collector route: $e');
      return null;
    }
  }

  LatLng _getClosestPointOnSegment(
      LatLng point, LatLng lineStart, LatLng lineEnd) {
    // Vector from start to end
    final dx = lineEnd.longitude - lineStart.longitude;
    final dy = lineEnd.latitude - lineStart.latitude;

    // If start and end are the same, return start
    if (dx == 0 && dy == 0) return lineStart;

    // Parameter t of the projection onto the line
    final t = ((point.longitude - lineStart.longitude) * dx +
            (point.latitude - lineStart.latitude) * dy) /
        (dx * dx + dy * dy);

    // Clamp t to [0, 1] to stay on the segment
    final tClamped = t.clamp(0.0, 1.0);

    // Calculate closest point
    return LatLng(
      lineStart.latitude + tClamped * dy,
      lineStart.longitude + tClamped * dx,
    );
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (photo != null) {
        setState(() {
          _imageFile = File(photo.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error taking photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _imageFile = File(image.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showImageSourceDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Image Source'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitReport() async {
    if (_selectedIssue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an issue type'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Require description if "Other Issues" is selected
    if (_selectedIssue == 'other_issues' &&
        _descriptionController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please provide a description for "Other Issues"'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location not available. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Show confirmation dialog
    final confirmed = await _showConfirmationDialog();
    if (!confirmed) return;

    setState(() => _isSubmitting = true);

    try {
      final user = FirebaseAuth.instance.currentUser;

      await _firestoreService.addGarbageReport(
        latitude: _currentPosition!.latitude,
        longitude: _currentPosition!.longitude,
        address: _locationText,
        reportedBy: user?.uid ?? 'anonymous',
        issueType: _selectedIssue!,
        description: _descriptionController.text.trim(),
        photoPath: _imageFile?.path,
      );

      if (mounted) {
        // Show success dialog
        await _showSuccessDialog();

        // Reset form
        setState(() {
          _selectedIssue = null;
          _descriptionController.clear();
          _imageFile = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit report: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showLocationSnapDialog() {
    if (_originalPosition == null || _currentPosition == null) return;

    final distance = Geolocator.distanceBetween(
      _originalPosition!.latitude,
      _originalPosition!.longitude,
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    ).round();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.location_on, color: Color(0xFF00A86B)),
            SizedBox(width: 8),
            Text('Location Adjusted'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your trash report location has been automatically adjusted to the nearest collector route ($distance meters away).',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: LatLng(
                    _currentPosition!.latitude,
                    _currentPosition!.longitude,
                  ),
                  initialZoom: 16.0,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.binsync',
                  ),
                  MarkerLayer(
                    markers: [
                      // Original position (blue)
                      Marker(
                        point: LatLng(
                          _originalPosition!.latitude,
                          _originalPosition!.longitude,
                        ),
                        width: 40,
                        height: 40,
                        alignment: const Alignment(0.0, -0.9),
                        child: const Icon(
                          Icons.person_pin_circle,
                          color: Colors.blue,
                          size: 40,
                        ),
                      ),
                      // Snapped position (green)
                      Marker(
                        point: LatLng(
                          _currentPosition!.latitude,
                          _currentPosition!.longitude,
                        ),
                        width: 40,
                        height: 40,
                        alignment: const Alignment(0.0, -0.9),
                        child: const Icon(
                          Icons.location_on,
                          color: Color(0xFF00A86B),
                          size: 40,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Row(
              children: [
                Icon(Icons.person_pin_circle,
                    color: Colors.blue, size: 20),
                SizedBox(width: 4),
                Text('Your location', style: TextStyle(fontSize: 12)),
                SizedBox(width: 16),
                Icon(Icons.location_on,
                    color: Color(0xFF00A86B), size: 20),
                SizedBox(width: 4),
                Text('Adjusted location', style: TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'OK, Got it!',
              style: TextStyle(
                color: Color(0xFF00A86B),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _checkIfNearCollectorRoute(Position position) async {
    try {
      final routesSnapshot =
          await FirebaseFirestore.instance.collection('collector_routes').get();

      if (routesSnapshot.docs.isEmpty) return false;

      const Distance distanceCalc = Distance();
      final userPoint = LatLng(position.latitude, position.longitude);

      for (var routeDoc in routesSnapshot.docs) {
        final routeData = routeDoc.data();
        final routePoints = (routeData['routePoints'] as List?)
            ?.map((p) =>
                LatLng(p['latitude'] as double, p['longitude'] as double))
            .toList();

        if (routePoints == null || routePoints.isEmpty) continue;

        for (int i = 0; i < routePoints.length - 1; i++) {
          final closestPoint = _getClosestPointOnSegment(
            userPoint,
            routePoints[i],
            routePoints[i + 1],
          );
          final distance =
              distanceCalc.as(LengthUnit.Meter, userPoint, closestPoint);

          if (distance <= 35) {
            return true; // Within 35m of a route
          }
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  void _showNotNearRouteWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('Not Near Collection Route'),
          ],
        ),
        content: const Text(
          'Your location is not within 35 meters of any collector route. '
          'This trash may not be collected. Consider moving closer to a main road or street.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'OK',
              style:
                  TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _showConfirmationDialog() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: Color(0xFF00A86B),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.description,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Do you want to proceed with\nsubmitting the report?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              side: const BorderSide(color: Color(0xFF00A86B)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                color: Color(0xFF00A86B),
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00A86B),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text(
                              'Confirm',
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
                  ],
                ),
              ),
            );
          },
        ) ??
        false;
  }

  Future<void> _showSuccessDialog() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Color(0xFF00A86B),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Report has been sent!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A86B),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Back',
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: const Text(
          'BinSync',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.menu, color: Colors.white),
          onPressed: () {
            // Menu action
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Report History Section
            const Text(
              'Select an activity you want to report',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),

            // Scrollable Activity List
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: user == null
                  ? const Center(
                      child: Text(
                        'Please sign in to view activities',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('garbage_reports')
                          .where('reportedBy', isEqualTo: user.uid)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF00A86B),
                            ),
                          );
                        }

                        if (snapshot.hasError) {
                          return Center(
                            child: Text(
                              'Error: ${snapshot.error}',
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 14,
                              ),
                            ),
                          );
                        }

                        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                          return const Center(
                            child: Text(
                              'No activities yet',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 14,
                              ),
                            ),
                          );
                        }

                        // Sort in memory instead of using Firestore orderBy
                        final activities = snapshot.data!.docs.toList();
                        activities.sort((a, b) {
                          final aData = a.data() as Map<String, dynamic>;
                          final bData = b.data() as Map<String, dynamic>;
                          final aTimestamp = aData['timestamp'] as Timestamp?;
                          final bTimestamp = bData['timestamp'] as Timestamp?;

                          if (aTimestamp == null && bTimestamp == null) {
                            return 0;
                          }
                          if (aTimestamp == null) return 1;
                          if (bTimestamp == null) return -1;

                          return bTimestamp
                              .compareTo(aTimestamp); // descending order
                        });

                        // Limit to 10 most recent
                        final recentActivities = activities.take(10).toList();

                        return ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: recentActivities.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final activity = recentActivities[index];
                            final data =
                                activity.data() as Map<String, dynamic>;
                            final status = data['status'] as String;
                            final timestamp = data['timestamp'] as Timestamp?;
                            final date = timestamp?.toDate();
                            final reportId = activity.id;

                            // Format trash ID
                            final trashId = reportId
                                .substring(reportId.length - 4)
                                .toUpperCase();

                            // Determine icon and label based on status
                            IconData icon;
                            String label;
                            Color iconColor;

                            if (status == 'collected') {
                              icon = Icons.check_circle;
                              label = 'Trash Pickup';
                              iconColor = const Color(0xFF00A86B);
                            } else if (status == 'pending') {
                              icon = Icons.delete_outline;
                              label = 'Trash Threw';
                              iconColor = Colors.orange;
                            } else {
                              icon = Icons.cancel;
                              label = 'Cancelled';
                              iconColor = Colors.red;
                            }

                            final isSelected = _selectedActivityId == reportId;

                            return InkWell(
                              onTap: () {
                                setState(() {
                                  if (_selectedActivityId == reportId) {
                                    _selectedActivityId = null;
                                  } else {
                                    _selectedActivityId = reportId;
                                  }
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12, horizontal: 8),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF00A86B).withOpacity(0.1)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    // Icon
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: iconColor.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        icon,
                                        color: iconColor,
                                        size: 24,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // Details
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            label,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.black87,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          if (date != null)
                                            Text(
                                              DateFormat('MMMM dd, yyyy')
                                                  .format(date),
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey[600],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    // Time and ID
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        if (date != null)
                                          Text(
                                            DateFormat('h:mm a').format(date),
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.black87,
                                            ),
                                          ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Trash ID: $trashId',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(width: 8),
                                    // Selection indicator
                                    if (isSelected)
                                      const Icon(
                                        Icons.radio_button_checked,
                                        color: Color(0xFF00A86B),
                                        size: 20,
                                      )
                                    else
                                      Icon(
                                        Icons.radio_button_unchecked,
                                        color: Colors.grey[400],
                                        size: 20,
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),

            const SizedBox(height: 16),

            // Location tip banner
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF00A86B).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF00A86B).withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: Color(0xFF00A86B),
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Your location is automatically snapped to the nearest road to help collectors find the garbage easily.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[800],
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Issue type selection
            const Text(
              'What\'s the Issue?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1,
              ),
              itemCount: _issueTypes.length,
              itemBuilder: (context, index) {
                final issue = _issueTypes[index];
                final isSelected = _selectedIssue == issue['id'];

                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedIssue = issue['id'];
                    });
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF00A86B).withOpacity(0.1)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF00A86B)
                            : Colors.grey[300]!,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          issue['icon'],
                          size: 32,
                          color: isSelected
                              ? const Color(0xFF00A86B)
                              : issue['color'],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          issue['label'],
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? const Color(0xFF00A86B)
                                : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 24),

            // Description
            const Text(
              'Description',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Type description here...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF00A86B), width: 2),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Upload photo
            const Text(
              'Upload Photo (Optional)',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),

            if (_imageFile != null)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      _imageFile!,
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _imageFile = null;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else
              GestureDetector(
                onTap: _showImageSourceDialog,
                child: Container(
                  height: 120,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[300]!, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.camera_alt,
                          size: 40,
                          color: Color(0xFF00A86B),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Take Photo',
                          style: TextStyle(
                            color: Color(0xFF00A86B),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 24),

            // Submit button
            ElevatedButton(
              onPressed: _isSubmitting ? null : _submitReport,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A86B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      'Submit Report',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
