import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../services/collector_session_service.dart';

class CollectorStatsScreen extends StatefulWidget {
  const CollectorStatsScreen({super.key});

  @override
  State<CollectorStatsScreen> createState() => _CollectorStatsScreenState();
}

class _CollectorStatsScreenState extends State<CollectorStatsScreen> {
  final CollectorSessionService _sessionService = CollectorSessionService();

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    if (userId == null) {
      return const Scaffold(
        body: Center(child: Text('Please log in')),
      );
    }

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        title: const Text(
          'Statistics',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: false,
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDailyStats(userId),
            const SizedBox(height: 24),
            _buildWeeklyStats(userId),
            const SizedBox(height: 24),
            _buildSessionHistory(userId),
            const SizedBox(height: 24),
            _buildMissedBins(userId),
            const SizedBox(height: 24),
            _buildUserReports(userId),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyStats(String userId) {
    final today = DateTime.now();
    final startOfDay = DateTime(today.year, today.month, today.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('garbage_reports')
          .where('collectorId', isEqualTo: userId)
          .where('status', isEqualTo: 'collected')
          .where('collectedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('collectedAt', isLessThan: Timestamp.fromDate(endOfDay))
          .snapshots(),
      builder: (context, collectedSnapshot) {
        final collected = collectedSnapshot.data?.docs.length ?? 0;

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('tracking_sessions')
              .doc('${userId}_${_getDateString(today)}')
              .snapshots(),
          builder: (context, trackingSnapshot) {
            final trackingData =
                trackingSnapshot.data?.data() as Map<String, dynamic>?;
            final distance = (trackingData?['distance'] ?? 0.0) / 1000; // km
            final duration = (trackingData?['duration'] ?? 0) / 3600.0; // hours

            return _buildStatsCard(
              'Daily Statistics',
              [
                _buildStatRow('Total Collected', '$collected bins'),
                _buildStatRow(
                    'Distance Traveled', '${distance.toStringAsFixed(2)} km'),
                _buildStatRow(
                    'Time Worked', '${duration.toStringAsFixed(2)} hrs'),
              ],
              Colors.green.shade50,
            );
          },
        );
      },
    );
  }

  Widget _buildWeeklyStats(String userId) {
    final today = DateTime.now();
    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    final startOfWeekDay =
        DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day);
    final endOfWeek = startOfWeekDay.add(const Duration(days: 7));

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('garbage_reports')
          .where('collectorId', isEqualTo: userId)
          .where('status', isEqualTo: 'collected')
          .where('collectedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(startOfWeekDay))
          .where('collectedAt', isLessThan: Timestamp.fromDate(endOfWeek))
          .snapshots(),
      builder: (context, collectedSnapshot) {
        final collected = collectedSnapshot.data?.docs.length ?? 0;

        return FutureBuilder<Map<String, dynamic>>(
          future: _calculateWeeklyTracking(userId, startOfWeekDay, endOfWeek),
          builder: (context, trackingSnapshot) {
            final distance = trackingSnapshot.data?['distance'] ?? 0.0;
            final duration = trackingSnapshot.data?['duration'] ?? 0.0;

            return _buildStatsCard(
              'Weekly Statistics',
              [
                _buildStatRow('Total Collected', '$collected bins'),
                _buildStatRow(
                    'Distance Traveled', '${distance.toStringAsFixed(2)} km'),
                _buildStatRow(
                    'Time Worked', '${duration.toStringAsFixed(2)} hrs'),
              ],
              Colors.blue.shade50,
            );
          },
        );
      },
    );
  }

  Future<Map<String, dynamic>> _calculateWeeklyTracking(
      String userId, DateTime start, DateTime end) async {
    double totalDistance = 0.0;
    double totalDuration = 0.0;

    final trackingSnapshot = await FirebaseFirestore.instance
        .collection('tracking_sessions')
        .where('collectorId', isEqualTo: userId)
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThan: Timestamp.fromDate(end))
        .get();

    for (var doc in trackingSnapshot.docs) {
      final data = doc.data();
      totalDistance += (data['distance'] ?? 0.0);
      totalDuration += (data['duration'] ?? 0.0).toDouble();
    }

    return {
      'distance': totalDistance / 1000, // km
      'duration': totalDuration / 3600, // hours
    };
  }

  String _getDateString(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Widget _buildSessionHistory(String userId) {
    return StreamBuilder<QuerySnapshot>(
      stream: _sessionService.getCollectorSessions(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return _buildStatsCard(
            'Session History',
            [
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'No sessions yet. Start collecting to see your history!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
            ],
            Colors.blue.shade50,
          );
        }

        final sessions = snapshot.data!.docs.take(10).toList();

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Session History',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00A86B),
                ),
              ),
              const SizedBox(height: 16),
              ...sessions.map((doc) {
                final session = doc.data() as Map<String, dynamic>;
                final startTime = (session['startTime'] as Timestamp).toDate();
                final duration = session['duration'] ?? 0;
                final binsCollected = session['binsCollected'] ?? 0;

                // Get distance from tracking_sessions instead
                final dateString = _getDateString(startTime);
                final trackingDocId = '${userId}_$dateString';

                return FutureBuilder<DocumentSnapshot>(
                  future: FirebaseFirestore.instance
                      .collection('tracking_sessions')
                      .doc(trackingDocId)
                      .get(),
                  builder: (context, trackingSnapshot) {
                    final trackingData =
                        trackingSnapshot.data?.data() as Map<String, dynamic>?;
                    final distance = (trackingData?['distance'] ?? 0.0) / 1000;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: Colors.blue.shade50,
                      child: ListTile(
                        leading:
                            const Icon(Icons.history, color: Color(0xFF00A86B)),
                        title: Text(
                          DateFormat('MMM dd, yyyy').format(startTime),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${distance.toStringAsFixed(2)} km • '
                          '${(duration / 60).toStringAsFixed(0)} min • '
                          '$binsCollected bins',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                      ),
                    );
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMissedBins(String userId) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('collector_sessions')
          .where('collectorId', isEqualTo: userId)
          .orderBy('startTime', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return _buildStatsCard(
            'Missed Bins',
            [
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'No missed bins - great job! 🎉',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF00A86B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
            Colors.orange.shade50,
          );
        }

        final List<Map<String, dynamic>> allMissedBins = [];
        for (var doc in snapshot.data!.docs) {
          final session = doc.data() as Map<String, dynamic>;
          final missedBins = session['missedBins'] as List<dynamic>?;
          if (missedBins != null && missedBins.isNotEmpty) {
            final startTime = (session['startTime'] as Timestamp).toDate();
            for (var bin in missedBins) {
              allMissedBins.add({
                'date': startTime,
                'address': bin['address'] ?? 'Unknown location',
              });
            }
          }
        }

        if (allMissedBins.isEmpty) {
          return _buildStatsCard(
            'Missed Bins',
            [
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'No missed bins - great job! 🎉',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF00A86B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
            Colors.orange.shade50,
          );
        }

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Missed Bins (${allMissedBins.length})',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange,
                ),
              ),
              const SizedBox(height: 16),
              ...allMissedBins.take(10).map((bin) {
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: Colors.orange.shade50,
                  child: ListTile(
                    leading: const Icon(Icons.warning, color: Colors.orange),
                    title: Text(
                      bin['address'],
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      DateFormat('MMM dd, yyyy').format(bin['date']),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatsCard(String title, List<Widget> stats, Color bgColor) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF00A86B),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: stats,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, {bool isWarning = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: isWarning ? Colors.red.shade700 : Colors.black87,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isWarning ? Colors.red.shade700 : const Color(0xFF00A86B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserReports(String userId) {
    // Get reports from the last 2 months
    final twoMonthsAgo = DateTime.now().subtract(const Duration(days: 60));

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('garbage_reports')
          .where('collectorId', isEqualTo: userId)
          .where('status', isEqualTo: 'collected')
          .where('collectedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(twoMonthsAgo))
          .orderBy('collectedAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return _buildStatsCard(
            'User Reports',
            [
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'No user reports collected yet',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
            Colors.purple.shade50,
          );
        }

        final reports = snapshot.data!.docs;

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'User Reports (${reports.length})',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.purple,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Bins collected from user reports in the last 2 months',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 16),
              ...reports.take(20).map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final address = data['address'] ?? 'Unknown location';
                final collectedAt = data['collectedAt'] != null
                    ? (data['collectedAt'] as Timestamp).toDate()
                    : null;
                final description = data['description'] ?? '';
                final issueType = data['issueType'] ?? 'other';

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: Colors.purple.shade50,
                  child: ListTile(
                    leading: Icon(
                      _getIssueIcon(issueType),
                      color: Colors.purple,
                    ),
                    title: Text(
                      address,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (description.isNotEmpty)
                          Text(
                            description,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(
                          collectedAt != null
                              ? 'Collected: ${DateFormat('MMM dd, yyyy').format(collectedAt)}'
                              : 'Collected recently',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        issueType.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  IconData _getIssueIcon(String issueType) {
    switch (issueType.toLowerCase()) {
      case 'overflowing':
        return Icons.delete_forever;
      case 'damaged':
        return Icons.broken_image;
      case 'misplaced':
        return Icons.wrong_location;
      case 'other':
      default:
        return Icons.report_problem;
    }
  }
}
