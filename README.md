<div align="center">

# ♻️ BinSync

**Resident–collector coordination · Maps · Routes · Notifications**

![Flutter](https://img.shields.io/badge/Flutter-Mobile-02569B?logo=flutter&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-Auth%20%26%20Firestore-FFCA28?logo=firebase&logoColor=black)
![Dart](https://img.shields.io/badge/Dart-3%2B-0175C2?logo=dart&logoColor=white)
![Status](https://img.shields.io/badge/status-academic%20prototype-64748B)

</div>

## Overview

BinSync is a Flutter mobile application exploring how residents and waste collectors can coordinate collection activity with interactive maps, route tooling, location-aware screens, and notifications. It was developed as academic coursework at **West Visayas State University**.

The source includes more than the map demonstration described by the original README: it has separate resident and collector screens, Firebase-backed services, schedules, reports, and route-related components. The repository is an academic prototype; production deployment or real-world collection outcomes have not been independently verified.

## Feature tour

| Area | Implemented modules visible in this repository |
| --- | --- |
| Accounts and roles | Firebase Authentication, Firestore user records, resident and collector entry screens |
| Maps and location | OpenStreetMap via `flutter_map`, geolocation, map markers and collector map views |
| Collector workflows | Collector dashboard, route creation/recording/list screens, collection lists and statistics views |
| Resident workflows | Reporting, collection schedules, history, notifications and map views |
| Messaging | Firebase Cloud Messaging integration, local notification modules and notification scheduling |
| Routing | Route service, collector tracking and route-snapping service modules |

> **Scope note:** A screen or service in the source is not a claim of deployment, end-to-end acceptance testing, or guaranteed live location updates.

## Technology

- **Mobile:** Flutter, Dart, Material Design
- **Maps:** `flutter_map`, `latlong2`, `geolocator`, `geocoding`
- **Backend services:** Firebase Core, Authentication, Cloud Firestore, Cloud Messaging
- **Notifications and device access:** `flutter_local_notifications`, `permission_handler`, `flutter_foreground_task`
- **Networking:** `http` and map/routing-related APIs

## Project structure

```text
lib/
├── main.dart                   # App bootstrap, Firebase init, role-based entry
├── map.dart                    # Map-based prototype views
├── screens/                    # Resident and collector interface screens
├── services/                   # Auth, location, routing, tracking, notifications
├── widgets/                    # Reusable UI
└── firebase_options.dart       # App-level Firebase configuration
android/ · ios/ · assets/       # Flutter platform and image assets
```

## Run locally

1. Install a Flutter SDK compatible with the Dart constraint in `pubspec.yaml`.
2. Clone this repository:
   ```bash
   git clone https://github.com/GinnoLmao/Binsync.git
   cd Binsync
   flutter pub get
   ```
3. Configure a **Firebase project you own** and register the Android/iOS app. Review `lib/firebase_options.dart` and the Firebase rules/configuration before running against any live data.
4. Launch on a compatible device or emulator:
   ```bash
   flutter run
   ```

Map tiles, geolocation permissions, notifications, and Firebase-backed workflows require their corresponding services and device permissions. Some features may need additional platform configuration.

## Contributors

This was an academic collaboration. The original project documentation credits **Zuriel Eliazar Calix** with lead application development and **Ginno D. Arostique Jr.** with project management, feature planning, UI/UX direction and documentation. Preserve contributor attribution when reusing the project.

## Responsible use

Do not commit Firebase service-account credentials, private location histories, real user records, access tokens, or production configuration secrets. Review Firestore security rules before connecting real accounts. No live municipal or commercial deployment is claimed here.
