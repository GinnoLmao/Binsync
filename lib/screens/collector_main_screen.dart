import 'package:flutter/material.dart';
import 'collector_home_screen.dart';
import 'collector_trash_list_screen.dart';
import 'collector_map_with_route_screen.dart';
import 'collector_stats_screen.dart';
import 'route_list_screen.dart';
import '../services/route_service.dart';
import 'package:latlong2/latlong.dart';

class CollectorMainScreen extends StatefulWidget {
  const CollectorMainScreen({super.key});

  @override
  State<CollectorMainScreen> createState() => _CollectorMainScreenState();
}

class _CollectorMainScreenState extends State<CollectorMainScreen>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;
  final RouteService _routeService = RouteService();

  String? _activeRouteId;
  String? _activeRouteName;
  List<LatLng>? _activeRoutePoints;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadActiveRoute();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reload route when app comes back to foreground
    if (state == AppLifecycleState.resumed) {
      _loadActiveRoute();
    }
  }

  Future<void> _loadActiveRoute() async {
    final route = await _routeService.getActiveRoute();
    if (mounted) {
      setState(() {
        if (route != null) {
          _activeRouteId = route['id'];
          _activeRouteName = route['name'];
          _activeRoutePoints = (route['points'] as List)
              .map((p) => LatLng(p['latitude'], p['longitude']))
              .toList();
        }
        _isLoading = false;
      });
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final screens = [
      CollectorHomeScreen(onNavigateToMap: () {
        setState(() {
          _selectedIndex = 2;
        });
      }, onNavigateToStats: () {
        setState(() {
          _selectedIndex = 3;
        });
      }),
      const CollectorTrashListScreen(),
      _activeRouteId != null &&
              _activeRouteName != null &&
              _activeRoutePoints != null
          ? CollectorMapWithRouteScreen(
              routeId: _activeRouteId!,
              routeName: _activeRouteName!,
              routePoints: _activeRoutePoints!,
              showBackButton: true,
              onBackPressed: () {
                setState(() {
                  _activeRouteId = null;
                  _activeRouteName = null;
                  _activeRoutePoints = null;
                });
              },
            )
          : const RouteListScreen(),
      const CollectorStatsScreen(),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          selectedItemColor: const Color(0xFF00A86B),
          unselectedItemColor: Colors.grey,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          elevation: 0,
          backgroundColor: Colors.white,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.delete_outline),
              activeIcon: Icon(Icons.delete),
              label: 'Trash',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              activeIcon: Icon(Icons.map),
              label: 'Map',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart_outlined),
              activeIcon: Icon(Icons.bar_chart),
              label: 'Stats',
            ),
          ],
        ),
      ),
    );
  }
}
