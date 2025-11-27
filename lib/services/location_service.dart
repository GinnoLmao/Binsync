import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  LatLng? _currentLocation;
  LatLng? _savedMapPosition;
  double _savedZoom = 16.0;
  bool _isInitialized = false;
  bool _isLoading = false;

  LatLng? get currentLocation => _currentLocation;
  LatLng? get savedMapPosition => _savedMapPosition;
  double get savedZoom => _savedZoom;
  bool get isInitialized => _isInitialized;

  void saveMapPosition(LatLng position, double zoom) {
    _savedMapPosition = position;
    _savedZoom = zoom;
  }

  void resetToCurrentLocation() {
    _savedMapPosition = null;
  }

  Future<LatLng?> initializeLocation() async {
    if (_isInitialized && _currentLocation != null) {
      return _currentLocation;
    }

    if (_isLoading) {
      // Wait for the current loading to complete
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _currentLocation;
    }

    _isLoading = true;

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _isLoading = false;
        throw Exception('Location services are disabled');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _isLoading = false;
          throw Exception('Location permissions are denied');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _isLoading = false;
        throw Exception('Location permissions are permanently denied');
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );

      _currentLocation = LatLng(position.latitude, position.longitude);
      _isInitialized = true;
      _isLoading = false;
      return _currentLocation;
    } catch (e) {
      _isLoading = false;
      print('Location error: $e');
      // Default to San Francisco
      _currentLocation = const LatLng(37.7749, -122.4194);
      _isInitialized = true;
      return _currentLocation;
    }
  }

  LatLng getMapCenter() {
    // Priority: saved position > current location > default
    if (_savedMapPosition != null) {
      return _savedMapPosition!;
    }
    if (_currentLocation != null) {
      return _currentLocation!;
    }
    return const LatLng(37.7749, -122.4194); // Default to San Francisco
  }
}
