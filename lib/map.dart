import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'dart:async';
import 'package:binsync/services/firestore_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapController? _mapController;

  // Default location (will be updated with user's location)
  LatLng _initialCenter = const LatLng(37.7749, -122.4194); // San Francisco
  LatLng _currentPinLocation = const LatLng(37.7749, -122.4194);
  final double _initialZoom = 13.0;
  bool _isLoadingLocation = true;
  String? _locationError;

  // Pin location feature
  bool _isPinning = false;
  bool _showDoneButton = false;
  String _locationText = '';
  Timer? _pinLockTimer;
  final FirestoreService _firestoreService = FirestoreService();
  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _pinLockTimer?.cancel();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _isLoadingLocation = false;
            _locationError =
                'Location services are disabled. Please enable them in your device settings.';
          });
        }
        return;
      }

      // Check for location permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            setState(() {
              _isLoadingLocation = false;
              _locationError =
                  'Location permissions are denied. Please grant location access.';
            });
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _isLoadingLocation = false;
            _locationError =
                'Location permissions are permanently denied. Please enable them in app settings.';
          });
        }
        return;
      }

      // Get current position with best accuracy for navigation
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );

      if (mounted) {
        setState(() {
          _initialCenter = LatLng(position.latitude, position.longitude);
          _isLoadingLocation = false;
        });

        // Move map to current location (only if map is already displayed)
        if (_mapController != null && _locationError == null) {
          try {
            _mapController!.move(_initialCenter, _initialZoom);
          } catch (e) {
            // Map controller not ready yet, ignore
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
          _locationError = 'Error getting location: $e';
        });
      }
    }
  }

  void _startPinning() {
    setState(() {
      _isPinning = true;
      _showDoneButton = false;
      _currentPinLocation = _mapController?.camera.center ?? _initialCenter;
    });
  }

  void _onMapMove() {
    if (_isPinning && _mapController != null) {
      // Cancel previous timer
      _pinLockTimer?.cancel();

      setState(() {
        _showDoneButton = false;
        _currentPinLocation = _mapController!.camera.center;
      });

      // Start new timer - lock after 1 second of no interaction
      _pinLockTimer = Timer(const Duration(seconds: 1), () {
        _lockPin();
      });
    }
  }

  Future<void> _lockPin() async {
    if (!_isPinning) return;

    final center = _mapController?.camera.center ?? _currentPinLocation;

    try {
      // Try to get address from coordinates
      List<Placemark> placemarks = await placemarkFromCoordinates(
        center.latitude,
        center.longitude,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        setState(() {
          _locationText =
              '${place.street ?? ''}, ${place.locality ?? ''}, ${place.country ?? ''}'
                  .trim();
          if (_locationText.startsWith(',')) {
            _locationText = _locationText.substring(1).trim();
          }
        });
      }
    } catch (e) {
      // If geocoding fails, just show coordinates
      setState(() {
        _locationText =
            'Lat: ${center.latitude.toStringAsFixed(6)}, Lng: ${center.longitude.toStringAsFixed(6)}';
      });
    }

    setState(() {
      _showDoneButton = true;
      _currentPinLocation = center;
    });
  }

  Future<void> _confirmLocation() async {
    // Show loading
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 16),
              Text('Saving location...'),
            ],
          ),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      // Save to Firestore
      await _firestoreService.addGarbageReport(
        latitude: _currentPinLocation.latitude,
        longitude: _currentPinLocation.longitude,
        address: _locationText,
      );

      setState(() {
        _isPinning = false;
        _showDoneButton = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 16),
                Text('Garbage location saved successfully!'),
              ],
            ),
            backgroundColor: Color(0xFF00A86B),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving location: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.menu, color: Colors.white),
          onPressed: () {},
        ),
        title: const Text(
          'Maps',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined,
                    color: Colors.white),
                onPressed: () {},
              ),
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  child: const Text(
                    '3',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoadingLocation
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00A86B)),
                  SizedBox(height: 16),
                  Text('Getting your location...'),
                ],
              ),
            )
          : _locationError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.location_off,
                          size: 64,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _locationError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: () {
                            setState(() {
                              _isLoadingLocation = true;
                              _locationError = null;
                            });
                            _getCurrentLocation();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController!,
                      options: MapOptions(
                        initialCenter: _initialCenter,
                        initialZoom: _initialZoom,
                        initialRotation: 0.0, // Start facing north
                        minZoom: 2.0,
                        maxZoom: 19.0,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                        ),
                        cameraConstraint: CameraConstraint.contain(
                          bounds: LatLngBounds(
                            const LatLng(-85.05115, -180.0),
                            const LatLng(85.05115, 180.0),
                          ),
                        ),
                        onPositionChanged: (position, hasGesture) {
                          if (hasGesture) {
                            _onMapMove();
                          }
                        },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.binsync',
                          maxZoom: 19,
                        ),
                      ],
                    ),
                    // Center pin icon
                    if (_isPinning)
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.location_on,
                              size: 48,
                              color: Color(0xFF00A86B),
                            ),
                            Container(
                              width: 4,
                              height: 4,
                              decoration: const BoxDecoration(
                                color: Color(0xFF00A86B),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Bottom sheet for pin location
                    if (_isPinning)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(20),
                              topRight: Radius.circular(20),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 10,
                                spreadRadius: 0,
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF00A86B)
                                          .withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      Icons.delete_outline,
                                      color: Color(0xFF00A86B),
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Pin location',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          'Drop pin on your exact location',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              if (_showDoneButton)
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.location_on_outlined,
                                        color: Color(0xFF00A86B),
                                        size: 20,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _locationText,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (_showDoneButton) const SizedBox(height: 16),
                              if (_showDoneButton)
                                SizedBox(
                                  width: double.infinity,
                                  height: 50,
                                  child: ElevatedButton(
                                    onPressed: _confirmLocation,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF00A86B),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      elevation: 0,
                                    ),
                                    child: const Text(
                                      'Confirm',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              if (!_showDoneButton)
                                const Center(
                                  child: Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 8.0),
                                    child: Text(
                                      'Drag map to position pin',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // North alignment button (always visible)
          FloatingActionButton(
            heroTag: 'north',
            mini: true,
            onPressed: () {
              _mapController?.rotate(0.0);
            },
            backgroundColor: Colors.white,
            child: const Icon(Icons.navigation, color: Color(0xFF00A86B)),
          ),
          const SizedBox(height: 10),
          // Pin location button (only when not pinning)
          if (!_isPinning) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 70),
              child: FloatingActionButton(
                heroTag: 'pin',
                onPressed: _startPinning,
                backgroundColor: const Color(0xFF00A86B),
                child: const Icon(Icons.add_location, color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
