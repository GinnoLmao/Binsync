import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Add a new garbage report
  Future<String> addGarbageReport({
    required double latitude,
    required double longitude,
    required String address,
    String? reportedBy,
  }) async {
    try {
      DocumentReference docRef = await _db.collection('garbage_reports').add({
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
        'reportedBy': reportedBy ?? 'anonymous',
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'pending', // pending, collected, cancelled
        'collectorId': null,
      });
      return docRef.id;
    } catch (e) {
      throw Exception('Failed to add garbage report: $e');
    }
  }

  // Get all pending garbage reports
  Stream<List<GarbageReport>> getPendingReports() {
    return _db
        .collection('garbage_reports')
        .where('status', isEqualTo: 'pending')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return GarbageReport.fromFirestore(doc);
      }).toList();
    });
  }

  // Get all garbage reports (for stats)
  Stream<List<GarbageReport>> getAllReports() {
    return _db
        .collection('garbage_reports')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return GarbageReport.fromFirestore(doc);
      }).toList();
    });
  }

  // Update report status
  Future<void> updateReportStatus(String reportId, String status) async {
    try {
      await _db.collection('garbage_reports').doc(reportId).update({
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Failed to update report status: $e');
    }
  }

  // Delete a report
  Future<void> deleteReport(String reportId) async {
    try {
      await _db.collection('garbage_reports').doc(reportId).delete();
    } catch (e) {
      throw Exception('Failed to delete report: $e');
    }
  }
}

// Model class for garbage reports
class GarbageReport {
  final String id;
  final double latitude;
  final double longitude;
  final String address;
  final String reportedBy;
  final DateTime? timestamp;
  final String status;
  final String? collectorId;

  GarbageReport({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.reportedBy,
    this.timestamp,
    required this.status,
    this.collectorId,
  });

  // Create from Firestore document
  factory GarbageReport.fromFirestore(DocumentSnapshot doc) {
    Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
    return GarbageReport(
      id: doc.id,
      latitude: data['latitude'] ?? 0.0,
      longitude: data['longitude'] ?? 0.0,
      address: data['address'] ?? '',
      reportedBy: data['reportedBy'] ?? 'anonymous',
      timestamp: data['timestamp'] != null
          ? (data['timestamp'] as Timestamp).toDate()
          : null,
      status: data['status'] ?? 'pending',
      collectorId: data['collectorId'],
    );
  }

  // Convert to LatLng for map display
  LatLng get location => LatLng(latitude, longitude);
}
