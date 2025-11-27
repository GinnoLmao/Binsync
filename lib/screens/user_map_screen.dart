import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:io';
import '../services/firestore_service.dart';
import '../services/location_service.dart';

class UserMapScreen extends StatefulWidget {
  final bool autoStartPinning;

  const UserMapScreen({super.key, this.autoStartPinning = false});

  @override
  State<UserMapScreen> createState() => _UserMapScreenState();
}

class _UserMapScreenState extends State<UserMapScreen> {
  late final MapController _mapController;
  late LatLng _initialCenter;
  late double _initialZoom;
  bool _isLoadingLocation = false;
  String? _locationError;

  // Pin placement
  bool _isPinning = false;
  LatLng? _pinnedLocation;
  String _pinnedAddress = '';
  Timer? _pinLockTimer;
  bool _showDoneButton = false;
  LatLng? _snappedLocation; // The location snapped to nearest route
  bool _isNearRoute = false; // Whether current location is near a route

  // User's trash reports
  List<GarbageReport> _userTrashReports = [];
  final FirestoreService _firestoreService = FirestoreService();

  @override
  void initState() {
    super.initState();
    _mapController = MapController();

    // Use LocationService to get map center (remembers last position)
    _initialCenter = LocationService().getMapCenter();
    _initialZoom = LocationService().savedZoom;
    _isLoadingLocation = !LocationService().isInitialized;

    if (!LocationService().isInitialized) {
      _initializeLocation();
    }

    _loadUserTrashReports();

    if (widget.autoStartPinning) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _startPinning();
      });
    }
  }

  Future<void> _initializeLocation() async {
    try {
      await LocationService().initializeLocation();
      if (mounted) {
        setState(() {
          _initialCenter = LocationService().getMapCenter();
          _isLoadingLocation = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
          _locationError = 'Error getting location: ${e.toString()}';
        });
      }
    }
  }

  @override
  void dispose() {
    // Save current map position before disposing (only if map is initialized)
    try {
      final center = _mapController.camera.center;
      final zoom = _mapController.camera.zoom;
      LocationService().saveMapPosition(center, zoom);
    } catch (e) {
      // Map controller not fully initialized, skip saving position
      print('Could not save map position: $e');
    }

    _pinLockTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserTrashReports() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _firestoreService.getUserReports(user.uid).listen((reports) {
      if (mounted) {
        setState(() {
          _userTrashReports = reports;
        });
      }
    });
  }

  void _startPinning() {
    setState(() {
      _isPinning = true;
      _showDoneButton = false;
      _pinnedLocation = null;
    });
  }

  void _onMapMove() {
    if (_isPinning) {
      _pinLockTimer?.cancel();
      setState(() {
        _showDoneButton = false;
      });

      _pinLockTimer = Timer(const Duration(milliseconds: 800), () {
        _lockPin();
      });

      // Check if location will snap to a route
      _checkIfNearRoute();
    }
  }

  Future<void> _checkIfNearRoute() async {
    if (!_isPinning) return;

    final center = _mapController.camera.center;

    try {
      // Check all collector routes
      final routesSnapshot =
          await FirebaseFirestore.instance.collection('collector_routes').get();

      if (routesSnapshot.docs.isEmpty) {
        setState(() {
          _isNearRoute = false;
          _snappedLocation = null;
        });
        return;
      }

      LatLng? nearestPoint;
      double minDistance = double.infinity;
      const distanceCalc = Distance();

      for (var routeDoc in routesSnapshot.docs) {
        final routeData = routeDoc.data();
        final routePoints = (routeData['routePoints'] as List?)
            ?.map((p) =>
                LatLng(p['latitude'] as double, p['longitude'] as double))
            .toList();

        if (routePoints == null || routePoints.isEmpty) continue;

        for (int i = 0; i < routePoints.length - 1; i++) {
          final closestPoint = _getClosestPointOnSegment(
            center,
            routePoints[i],
            routePoints[i + 1],
          );
          final distance =
              distanceCalc.as(LengthUnit.Meter, center, closestPoint);

          if (distance < minDistance) {
            minDistance = distance;
            nearestPoint = closestPoint;
          }
        }
      }

      if (mounted) {
        setState(() {
          _isNearRoute = minDistance <= 35; // 35 meters
          _snappedLocation = _isNearRoute ? nearestPoint : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isNearRoute = false;
          _snappedLocation = null;
        });
      }
    }
  }

  LatLng _getClosestPointOnSegment(
      LatLng point, LatLng lineStart, LatLng lineEnd) {
    final dx = lineEnd.longitude - lineStart.longitude;
    final dy = lineEnd.latitude - lineStart.latitude;

    if (dx == 0 && dy == 0) return lineStart;

    final t = ((point.longitude - lineStart.longitude) * dx +
            (point.latitude - lineStart.latitude) * dy) /
        (dx * dx + dy * dy);

    final tClamped = t.clamp(0.0, 1.0);

    return LatLng(
      lineStart.latitude + tClamped * dy,
      lineStart.longitude + tClamped * dx,
    );
  }

  Future<void> _lockPin() async {
    if (!_isPinning) return;

    final center = _mapController.camera.center;

    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        center.latitude,
        center.longitude,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        final address =
            '${place.street ?? ''}, ${place.locality ?? ''}, ${place.country ?? ''}'
                .replaceAll(RegExp(r'^,\s*|,\s*$'), '');

        setState(() {
          _pinnedAddress = address.isNotEmpty ? address : 'Unknown location';
          _showDoneButton = true;
        });
      }
    } catch (e) {
      setState(() {
        _pinnedAddress = 'Unable to get address';
        _showDoneButton = true;
      });
    }
  }

  void _confirmPinLocation() {
    setState(() {
      _pinnedLocation = _mapController.camera.center;
      _isPinning = false;
    });

    _showTrashDetailsDialog();
  }

  void _cancelPinning() {
    setState(() {
      _isPinning = false;
      _showDoneButton = false;
      _pinnedLocation = null;
    });
  }

  void _showTrashDetailsDialog() {
    if (_pinnedLocation == null) return;

    final descriptionController = TextEditingController();
    File? photoFile;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Header with full green background extending to edges
              Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: Color(0xFF00A86B),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Throw a Trash?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Fill in the Necessary Information',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Location info
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00A86B).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.delete,
                              color: Color(0xFF00A86B),
                              size: 24,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _pinnedAddress,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.access_time,
                                        size: 12,
                                        color: Color(0xFF00A86B),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Now',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Description
                      const Text(
                        'Description',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: descriptionController,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Please describe the trash location...',
                          hintStyle: TextStyle(color: Colors.grey[400]),
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
                                const BorderSide(color: Color(0xFF00A86B)),
                          ),
                          filled: true,
                          fillColor: Colors.grey[50],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Photo upload
                      const Text(
                        'Upload Photo (Optional)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () async {
                          final ImagePicker picker = ImagePicker();
                          final XFile? image = await picker.pickImage(
                            source: ImageSource.camera,
                            imageQuality: 70,
                          );
                          if (image != null) {
                            setModalState(() {
                              photoFile = File(image.path);
                            });
                          }
                        },
                        child: Container(
                          height: 120,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: const Color(0xFF00A86B),
                              width: 2,
                              style: BorderStyle.solid,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: photoFile != null
                              ? Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Image.file(
                                        photoFile!,
                                        width: double.infinity,
                                        height: double.infinity,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: GestureDetector(
                                        onTap: () {
                                          setModalState(() {
                                            photoFile = null;
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
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : const Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.camera_alt,
                                        color: Color(0xFF00A86B),
                                        size: 40,
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        'Take Photo',
                                        style: TextStyle(
                                          color: Color(0xFF00A86B),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Note: Your current location will be used as the trash location.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom buttons
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, -5),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          setState(() {
                            _pinnedLocation = null;
                          });
                        },
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          side: const BorderSide(color: Color(0xFF00A86B)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
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
                        onPressed: () async {
                          if (_pinnedLocation == null) return;

                          final user = FirebaseAuth.instance.currentUser;
                          if (user == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Please login first')),
                            );
                            return;
                          }

                          try {
                            await _firestoreService.addGarbageReport(
                              latitude: _pinnedLocation!.latitude,
                              longitude: _pinnedLocation!.longitude,
                              address: _pinnedAddress,
                              reportedBy: user.uid,
                              description: descriptionController.text,
                              photoPath: photoFile?.path,
                            );

                            if (!mounted) return;

                            // Close the modal first
                            if (Navigator.canPop(context)) {
                              Navigator.pop(context);
                            }

                            // Show success dialog and wait for it to close
                            await showDialog(
                              context: context,
                              barrierDismissible: false,
                              builder: (dialogContext) => const SuccessDialog(),
                            );

                            // After dialog closes, navigate back to home
                            if (mounted && Navigator.canPop(context)) {
                              Navigator.pop(context);
                            }
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error: $e')),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: const Color(0xFF00A86B),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTrashDetailsForRemoval(GarbageReport report) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.6,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Header with full green background extending to edges
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              decoration: const BoxDecoration(
                color: Color(0xFF00A86B),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Trash Details',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Location
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00A86B).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            color: Color(0xFF00A86B),
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              report.address,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Description
                    if (report.description.isNotEmpty) ...[
                      const Text(
                        'Description',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        report.description,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // Photo
                    if (report.photoPath != null &&
                        report.photoPath!.isNotEmpty) ...[
                      const Text(
                        'Photo',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(report.photoPath!),
                          width: double.infinity,
                          height: 200,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Bottom buttons
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: BorderSide(color: Colors.grey[400]!),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Back',
                        style: TextStyle(
                          color: Colors.grey[700],
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        try {
                          await _firestoreService.deleteReport(report.id);
                          if (!mounted) return;
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Trash marker removed'),
                              backgroundColor: Color(0xFF00A86B),
                            ),
                          );
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Error: $e')),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.red,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Remove',
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
    );
  }

  void _centerOnUserLocation() {
    if (!_isLoadingLocation) {
      try {
        // Reset saved position and go to current location
        LocationService().resetToCurrentLocation();
        final currentLocation = LocationService().currentLocation;
        if (currentLocation != null) {
          _mapController.move(currentLocation, _initialZoom);
        }
      } catch (e) {
        print('Error centering map: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingLocation) {
      return const Scaffold(
        backgroundColor: Color(0xFF00A86B),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                'Getting your location...',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }

    if (_locationError != null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF00A86B),
          title: const Text('Map', style: TextStyle(color: Colors.white)),
          centerTitle: true,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.location_off, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  _locationError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[700], fontSize: 16),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isLoadingLocation = true;
                      _locationError = null;
                    });
                    _initializeLocation();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A86B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    Geolocator.openLocationSettings();
                  },
                  child: const Text(
                    'Open Settings',
                    style: TextStyle(color: Color(0xFF00A86B)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: const Text(
          'Trash Map',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          if (!_isPinning)
            IconButton(
              icon: const Icon(Icons.my_location, color: Colors.white),
              onPressed: _centerOnUserLocation,
            ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _initialCenter,
              initialZoom: _initialZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (position, hasGesture) {
                if (hasGesture) _onMapMove();
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.binsync',
              ),
              // User location marker
              MarkerLayer(
                markers: [
                  Marker(
                    point: _initialCenter,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.3),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.circle,
                        color: Colors.blue,
                        size: 16,
                      ),
                    ),
                  ),
                  // User's trash markers
                  ..._userTrashReports.map((report) {
                    return Marker(
                      point: LatLng(report.latitude, report.longitude),
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () => _showTrashDetailsForRemoval(report),
                        child: const Icon(
                          Icons.delete_rounded,
                          color: Colors.red,
                          size: 40,
                        ),
                      ),
                    );
                  }),
                  // Snapped location indicator (show where pin will actually be placed)
                  if (_isPinning && _snappedLocation != null)
                    Marker(
                      point: _snappedLocation!,
                      width: 30,
                      height: 30,
                      alignment: const Alignment(0.0, -0.9),
                      child: const Icon(
                        Icons.circle,
                        size: 12,
                        color: Color(0xFF00A86B),
                      ),
                    ),
                ],
              ),
            ],
          ),

          // Center pin when pinning mode
          if (_isPinning)
            Align(
              alignment: const Alignment(0.0, -0.05),
              child: Icon(
                Icons.location_on,
                size: 48,
                color: _isNearRoute ? const Color(0xFF00A86B) : Colors.grey,
              ),
            ),

          // Message when not near route
          if (_isPinning && !_isNearRoute && _showDoneButton)
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.block, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'That road is not routed for collection',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Top location banner when pinning
          if (_isPinning && _pinnedAddress.isNotEmpty)
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
                child: Row(
                  children: [
                    const Icon(
                      Icons.delete,
                      color: Color(0xFF00A86B),
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _pinnedAddress,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Done button when pin is locked (only if near route)
          if (_showDoneButton && _isNearRoute)
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _cancelPinning,
                      icon: const Icon(Icons.close, size: 20),
                      label: const Text('Cancel'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey[700],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _confirmPinLocation,
                      icon: const Icon(Icons.check, size: 20),
                      label: const Text('Confirm Location'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A86B),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: !_isPinning
          ? FloatingActionButton.extended(
              onPressed: _startPinning,
              backgroundColor: const Color(0xFF00A86B),
              icon: const Icon(Icons.add_location_alt, color: Colors.white),
              label: const Text(
                'Add Trash',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : null,
    );
  }
}

// Floating success dialog
class SuccessDialog extends StatefulWidget {
  const SuccessDialog({super.key});

  @override
  State<SuccessDialog> createState() => _SuccessDialogState();
}

class _SuccessDialogState extends State<SuccessDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _scaleAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.elasticOut,
    );

    _controller.forward();

    // Auto dismiss after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pop(context);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: const Color(0xFF00A86B),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  size: 50,
                  color: Color(0xFF00A86B),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Trash Recorded',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Successfully added to the map',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
