# Binsync App Flow Diagram

## Application Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         main()                               │
│                    Entry Point                               │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                     BinsyncApp                               │
│                 (StatelessWidget)                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ • MaterialApp Configuration                          │   │
│  │ • Theme Setup (Green, Material 3)                   │   │
│  │ • Title: "Binsync - Garbage Tracking"               │   │
│  └─────────────────────────────────────────────────────┘   │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      MapScreen                               │
│                 (StatefulWidget)                             │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                  _MapScreenState                             │
│                  (State<MapScreen>)                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ State Variables:                                     │   │
│  │ • _mapController: MapController                     │   │
│  │ • _initialCenter: LatLng (SF coordinates)           │   │
│  │ • _initialZoom: double (13.0)                       │   │
│  │ • _markers: List<Marker> (dynamic list)             │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Lifecycle Methods:                                   │   │
│  │ • initState() → _initializeMarkers()                │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Helper Methods:                                      │   │
│  │ • _initializeMarkers(): Load 3 sample markers       │   │
│  │ • _addMarker(LatLng): Add new marker at point      │   │
│  └─────────────────────────────────────────────────────┘   │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      UI Structure                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Scaffold                                             │   │
│  │  ├─ AppBar                                          │   │
│  │  │   ├─ Title: "Binsync - Garbage Tracking"        │   │
│  │  │   └─ Actions: [Reset Location Button]           │   │
│  │  │                                                   │   │
│  │  ├─ Body: FlutterMap                               │   │
│  │  │   ├─ TileLayer (OpenStreetMap)                  │   │
│  │  │   └─ MarkerLayer (Garbage bins)                 │   │
│  │  │                                                   │   │
│  │  └─ FloatingActionButton (Column)                  │   │
│  │      ├─ Zoom In (+)                                │   │
│  │      ├─ Zoom Out (-)                               │   │
│  │      └─ Clear Markers                              │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Component Details

### FlutterMap Widget Structure

```
FlutterMap
├── mapController: _mapController
├── options: MapOptions
│   ├── initialCenter: LatLng(37.7749, -122.4194)
│   ├── initialZoom: 13.0
│   └── onTap: _addMarker(point)
│
└── children: [
    ├── TileLayer
    │   ├── urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
    │   ├── userAgentPackageName: 'com.example.binsync'
    │   └── maxZoom: 19
    │
    └── MarkerLayer
        └── markers: _markers (List<Marker>)
]
```

## User Interaction Flow

```
User Action                    App Response
──────────────────────────────────────────────────────────
1. App Launch          →      • Initialize app
                               • Load MapScreen
                               • Create 3 sample markers
                               • Display OpenStreetMap

2. Tap on Map          →      • Capture tap coordinates
                               • Call _addMarker(point)
                               • Create blue marker
                               • Update UI with setState

3. Click Zoom In (+)   →      • Get current zoom level
                               • Increment zoom by 1
                               • Update map view
                               • Smooth zoom animation

4. Click Zoom Out (-)  →      • Get current zoom level
                               • Decrement zoom by 1
                               • Update map view
                               • Smooth zoom animation

5. Click Reset         →      • Get initial coordinates
                               • Move to initial location
                               • Reset zoom to 13.0
                               • Smooth pan animation

6. Click Clear         →      • Clear all markers
                               • Call _initializeMarkers()
                               • Restore 3 sample markers
                               • Update UI with setState

7. Pan Map             →      • Drag gesture detected
                               • Update map center
                               • Load new tiles if needed
                               • Smooth panning

8. Pinch Zoom          →      • Pinch gesture detected
                               • Calculate zoom change
                               • Update zoom level
                               • Load appropriate tiles
```

## State Management Flow

```
┌──────────────┐
│ User Action  │
└──────┬───────┘
       │
       ▼
┌──────────────────┐
│  Event Handler   │
│  (onPressed,     │
│   onTap, etc.)   │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│  State Update    │
│  (setState)      │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│  Widget Rebuild  │
│  (build method)  │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│  UI Update       │
│  (Screen render) │
└──────────────────┘
```

## Marker Management

```
Marker Types:
┌────────────────────────────────────────┐
│ Pre-loaded Markers (3):                │
│  1. Red    @ (37.7749, -122.4194)     │
│  2. Green  @ (37.7849, -122.4094)     │
│  3. Orange @ (37.7649, -122.4294)     │
└────────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────┐
│ User-Added Markers:                    │
│  • Blue @ (tap location)               │
│  • Added dynamically                   │
│  • Unlimited count                     │
└────────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────┐
│ All markers stored in:                 │
│  List<Marker> _markers                 │
└────────────────────────────────────────┘
```

## Data Flow

```
OpenStreetMap Server
        │
        │ HTTPS Request
        ▼
┌──────────────────┐
│   TileLayer      │  ← Fetches map tiles
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Map Display     │  ← Renders tiles
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  MarkerLayer     │  ← Overlays markers
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  User sees map   │
│  with markers    │
└──────────────────┘
```

## Widget Tree

```
MaterialApp
 └── MapScreen (StatefulWidget)
      └── Scaffold
           ├── AppBar
           │    ├── Text("Binsync - Garbage Tracking")
           │    └── IconButton (my_location)
           │
           ├── Body
           │    └── FlutterMap
           │         ├── TileLayer
           │         └── MarkerLayer
           │              └── List<Marker>
           │                   ├── Marker (Red)
           │                   ├── Marker (Green)
           │                   ├── Marker (Orange)
           │                   └── Marker (Blue) × n
           │
           └── FloatingActionButton (Column)
                ├── FAB (Zoom In)
                ├── SizedBox (Spacer)
                ├── FAB (Zoom Out)
                ├── SizedBox (Spacer)
                └── FAB (Clear)
```

## Execution Timeline

```
Time  Event
─────────────────────────────────────────────
T0    main() called
      │
T1    BinsyncApp created
      │
T2    MaterialApp builds
      │
T3    MapScreen widget created
      │
T4    _MapScreenState initialized
      │
T5    initState() called
      │
T6    _initializeMarkers() executed
      │  • 3 markers created
      │
T7    build() method called
      │
T8    Scaffold rendered
      │
T9    FlutterMap widget builds
      │
T10   TileLayer starts loading tiles
      │
T11   Map tiles loaded and displayed
      │
T12   MarkerLayer renders markers
      │
T13   UI fully rendered
      │
T14   App ready for user interaction
      │
...   User interactions handled
      │  • Tap → Add marker
      │  • Button → Zoom/Reset/Clear
      │
∞     Event loop continues
```

## Error Handling

```
Potential Issues:
┌────────────────────────────┐
│ Network connectivity       │ → Tiles may not load
│ Invalid coordinates        │ → Marker not added
│ Memory issues             │ → Too many markers
└────────────────────────────┘

Current Handling:
• Basic error tolerance
• No explicit error handling yet
• Future: Add try-catch blocks
• Future: Show error messages
• Future: Offline tile caching
```

## Performance Considerations

```
Optimization Points:
1. Tile Caching     → Reduce network requests
2. Marker Culling   → Hide off-screen markers
3. Lazy Loading     → Load tiles on demand
4. State Efficiency → Minimize rebuilds
5. Memory Management→ Clear unused tiles
```

---

**Note**: This diagram represents the current implementation. 
Future enhancements may add additional layers and complexity.
