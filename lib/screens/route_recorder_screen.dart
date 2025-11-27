import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import '../services/route_service.dart';

class RouteRecorderScreen extends StatefulWidget {
  const RouteRecorderScreen({super.key});

  @override
  State<RouteRecorderScreen> createState() => _RouteRecorderScreenState();
}

class _RouteRecorderScreenState extends State<RouteRecorderScreen> {
  final MapController _mapController = MapController();
  final RouteService _routeService = RouteService();
  final TextEditingController _routeNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  LatLng _currentLocation = const LatLng(14.5995, 120.9842);
  final List<LatLng> _recordedPoints = [];
  bool _isRecording = false;
  bool _isLoading = false;
  DateTime? _recordingStartTime;
  StreamSubscription<Position>? _positionStreamSubscription;

  // Recording statistics
  double _totalDistanceKm = 0.0;
  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    _durationTimer?.cancel();
    _routeNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _initializeLocation() async {
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
        });
        _mapController.move(_currentLocation, 16.0);
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
    }
  }

  void _startRecording() {
    setState(() {
      _isRecording = true;
      _recordedPoints.clear();
      _recordingStartTime = DateTime.now();
      _totalDistanceKm = 0.0;
      _recordingDuration = Duration.zero;
    });

    // Start duration timer
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isRecording && _recordingStartTime != null) {
        setState(() {
          _recordingDuration = DateTime.now().difference(_recordingStartTime!);
        });
      }
    });

    // Start location tracking
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5, // Record point every 5 meters
    );

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      if (mounted && _isRecording) {
        final newPoint = LatLng(position.latitude, position.longitude);

        // Calculate distance from last point
        if (_recordedPoints.isNotEmpty) {
          const distance = Distance();
          final distanceToLast = distance.as(
            LengthUnit.Kilometer,
            _recordedPoints.last,
            newPoint,
          );
          setState(() {
            _totalDistanceKm += distanceToLast;
          });
        }

        setState(() {
          _currentLocation = newPoint;
          _recordedPoints.add(newPoint);
        });

        // Auto-follow the current location
        _mapController.move(_currentLocation, _mapController.camera.zoom);
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Recording started! Drive your route.'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _stopRecording() {
    _positionStreamSubscription?.cancel();
    _durationTimer?.cancel();

    setState(() {
      _isRecording = false;
    });

    if (_recordedPoints.length < 10) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Route Too Short'),
          content: const Text(
            'The recorded route is too short. Please drive a longer route to save it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    _showSaveDialog();
  }

  Future<void> _showSaveDialog() async {
    final routeName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Save Recorded Route'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Distance: ${_totalDistanceKm.toStringAsFixed(2)} km',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                'Duration: ${_formatDuration(_recordingDuration)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                'Points: ${_recordedPoints.length}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
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
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Discard'),
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
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (routeName == null || routeName.isEmpty) {
      setState(() {
        _recordedPoints.clear();
        _totalDistanceKm = 0.0;
        _recordingDuration = Duration.zero;
      });
      return;
    }

    _saveRoute(routeName);
  }

  Future<void> _saveRoute(String routeName) async {
    setState(() => _isLoading = true);

    try {
      await _routeService.createRoute(
        routeName: routeName,
        routePoints: _recordedPoints,
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

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: const Text(
          'Record Route',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: _isRecording
              ? null
              : () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation,
              initialZoom: 16.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.binsync.app',
              ),
              // Recorded route polyline
              if (_recordedPoints.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _recordedPoints,
                      strokeWidth: 5.0,
                      color: _isRecording ? Colors.red : const Color(0xFF00A86B),
                    ),
                  ],
                ),
              // Current location marker
              MarkerLayer(
                markers: [
                  Marker(
                    point: _currentLocation,
                    width: 50,
                    height: 50,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _isRecording ? Colors.red : Colors.blue,
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
                      child: Icon(
                        _isRecording ? Icons.navigation : Icons.my_location,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                  // Start point marker
                  if (_recordedPoints.isNotEmpty)
                    Marker(
                      point: _recordedPoints.first,
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
                ],
              ),
            ],
          ),

          // Recording stats overlay
          if (_isRecording)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'RECORDING',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildStatItem(
                          'Distance',
                          '${_totalDistanceKm.toStringAsFixed(2)} km',
                        ),
                        _buildStatItem(
                          'Duration',
                          _formatDuration(_recordingDuration),
                        ),
                        _buildStatItem(
                          'Points',
                          '${_recordedPoints.length}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Instructions when not recording
          if (!_isRecording && _recordedPoints.isEmpty)
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
                        'Press START to begin recording your route while driving',
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

          // Control button
          Positioned(
            bottom: 24,
            left: 24,
            right: 24,
            child: ElevatedButton.icon(
              onPressed: _isRecording ? _stopRecording : _startRecording,
              icon: Icon(
                _isRecording ? Icons.stop : Icons.play_arrow,
                size: 28,
              ),
              label: Text(
                _isRecording ? 'STOP RECORDING' : 'START RECORDING',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRecording ? Colors.red : const Color(0xFF00A86B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 8,
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

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
