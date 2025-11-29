# BinSync

> A Resident–Collector Coordination and Notification System for Improved Waste Collection System

BinSync is a mobile application developed to support real-time residential waste-collection coordination through interactive mapping, bin-readiness reporting, and simplified route visualization. Built using the Flutter framework and integrated with OpenStreetMap, BinSync enables users to mark garbage bin locations, view collection areas, and interact with location-based features designed to make waste collection more timely, transparent, and efficient.

This project was developed as an academic requirement for the course **CC206 – App Development and Emerging Technologies** under the **Bachelor of Science in Computer Science, 3B-AI**, West Visayas State University.

---

## Overview

BinSync introduces a lightweight, map-driven approach to waste-collection coordination by allowing users to plot bin locations and interact with real-time map elements. Through a tap-to-mark interface, both residents and collectors can engage with bin data directly on an interactive OpenStreetMap surface. The system showcases how mobile technologies and geospatial mapping can help optimize collection visibility and support location-aware decision-making in communities.

The application's design emphasizes simplicity and practicality. Features such as adding markers, zoom controls, predefined sample bins, and reset functions allow users to intuitively explore and manage bin placements. Although this version of BinSync focuses primarily on demonstrating mapping and marker functionalities, it establishes the foundational components for more advanced waste-collection systems—such as real-time bin readiness, collection tracking, and route-based optimization.

---

## Features

- 🗺️ **Interactive Map Interface** integrating OpenStreetMap tiles
- 📍 **Add and modify garbage bin markers** directly on the map
- 🎯 **Pre-loaded sample bin locations** for testing and demonstration
- ➕ **Tap-to-Add Marker** capability
- 🔍 **Zoom in/out controls** for enhanced map navigation
- 📌 **Reset View** to return to the default location
- 🧹 **Clear all markers** to reset the map

---

## Prerequisites

Before running BinSync, ensure you have the following installed:

- **Flutter SDK** (3.0.0 or higher)
- **Dart** (3.0.0 or higher)
- A compatible IDE such as **Visual Studio Code** or **Android Studio**

---

## Getting Started

### Clone the Repository

```bash
git clone https://github.com/DukeZyke/Binsync.git
cd Binsync
```

### Install Dependencies

```bash
flutter pub get
```

### Run the Application

```bash
flutter run
```

---

## Project Structure

```
Binsync/
├── lib/
│   └── main.dart             # Core map implementation and UI
├── pubspec.yaml              # Project dependencies and Flutter settings
├── analysis_options.yaml     # Linting and code analysis rules
└── README.md                 # Project documentation
```

---

## Dependencies

- **flutter_map** – Map rendering and tile loading
- **latlong2** – Geolocation and coordinate utilities
- **cupertino_icons** – UI icon support

---

## Usage Summary

1. **Tap on the map** to add new bin markers
2. **Use zoom buttons** for map navigation
3. **Reset the map view** with the location button
4. **Clear all markers** to restore initial sample data

The system includes sample bin markers for demonstration, allowing users to immediately explore the interactive map environment.

---

## About the Developers

This project was created by students of the **Bachelor of Science in Computer Science – 3B AI**, West Visayas State University, as a final project for the course **CC206 – App Development and Emerging Technologies**.

### Zuriel Eliazar Calix – Lead Developer
Responsible for core application logic, Flutter integration, and mapping functionality.

### Ginno Arostique Jr. – Project Manager
Oversaw documentation, feature planning, UI/UX desgin, system structuring, and project direction.

Together, the developers designed BinSync as an academic prototype demonstrating the potential of mobile geospatial technologies in enhancing waste-collection workflows.

---

## License

This project is part of an academic requirement and is intended for educational purposes.
