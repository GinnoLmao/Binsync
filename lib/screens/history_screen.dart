import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../widgets/app_drawer.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Colors.white,
      drawer: const AppDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFF00A86B),
        elevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text(
          'BinSync',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: const Text(
              'Trash History',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),

          // History List
          Expanded(
            child: user == null
                ? const Center(
                    child: Text(
                      'Please sign in to view history',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('garbage_reports')
                        .where('reportedBy', isEqualTo: user.uid)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF00A86B),
                          ),
                        );
                      }

                      if (snapshot.hasError) {
                        return Center(
                          child: Text(
                            'Error: ${snapshot.error}',
                            style: const TextStyle(color: Colors.red),
                          ),
                        );
                      }

                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                        return const Center(
                          child: Text(
                            'No history yet',
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 16,
                            ),
                          ),
                        );
                      }

                      // Sort in memory by timestamp
                      final activities = snapshot.data!.docs.toList();
                      activities.sort((a, b) {
                        final aData = a.data() as Map<String, dynamic>;
                        final bData = b.data() as Map<String, dynamic>;
                        final aTimestamp = aData['timestamp'] as Timestamp?;
                        final bTimestamp = bData['timestamp'] as Timestamp?;

                        if (aTimestamp == null && bTimestamp == null) return 0;
                        if (aTimestamp == null) return 1;
                        if (bTimestamp == null) return -1;

                        return bTimestamp.compareTo(aTimestamp);
                      });

                      return ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: activities.length,
                        itemBuilder: (context, index) {
                          final activity = activities[index];
                          final data = activity.data() as Map<String, dynamic>;
                          final status = data['status'] as String;
                          final timestamp = data['timestamp'] as Timestamp?;
                          final date = timestamp?.toDate();
                          final reportId = activity.id;
                          final address =
                              data['address'] as String? ?? 'Unknown location';
                          final description =
                              data['description'] as String? ?? '';
                          final issueType = data['issueType'] as String? ?? '';
                          final photoPath = data['photoPath'] as String? ?? '';

                          final isPickup = status == 'collected';
                          final trashId = reportId
                              .substring(reportId.length - 4)
                              .toUpperCase();

                          return _HistoryCard(
                            isPickup: isPickup,
                            trashId: trashId,
                            address: address,
                            date: date,
                            reportId: reportId,
                            description: description,
                            issueType: issueType,
                            photoPath: photoPath,
                            onTap: () {
                              _showTrashDetailDialog(
                                context,
                                isPickup: isPickup,
                                trashId: trashId,
                                address: address,
                                date: date,
                                reportId: reportId,
                                description: description,
                                issueType: issueType,
                                photoPath: photoPath,
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showTrashDetailDialog(
    BuildContext context, {
    required bool isPickup,
    required String trashId,
    required String address,
    required DateTime? date,
    required String reportId,
    required String description,
    required String issueType,
    required String photoPath,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: isPickup
                      ? const Color(0xFF00A8E8)
                      : const Color(0xFFFFA500),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      isPickup ? Icons.check_circle : Icons.delete,
                      color: Colors.white,
                      size: 40,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isPickup ? 'Trash Pickup' : 'Trash Threw',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '#$trashId',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),

              // Content
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Location Info
                      Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            color: isPickup
                                ? const Color(0xFF00A8E8)
                                : const Color(0xFFFFA500),
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  address,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                                Text(
                                  'Truck ID: $trashId',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Date and Time
                      if (date != null) ...[
                        Row(
                          children: [
                            Icon(
                              Icons.calendar_today,
                              color: isPickup
                                  ? const Color(0xFF00A8E8)
                                  : const Color(0xFFFFA500),
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              DateFormat('EEEE').format(date),
                              style: TextStyle(
                                fontSize: 14,
                                color: isPickup
                                    ? const Color(0xFF00A8E8)
                                    : const Color(0xFFFFA500),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.access_time,
                              color: isPickup
                                  ? const Color(0xFF00A8E8)
                                  : const Color(0xFFFFA500),
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              DateFormat('h:mm a').format(date),
                              style: TextStyle(
                                fontSize: 14,
                                color: isPickup
                                    ? const Color(0xFF00A8E8)
                                    : const Color(0xFFFFA500),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Description (for Trash Threw)
                      if (!isPickup && description.isNotEmpty) ...[
                        const Text(
                          'Description',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            description,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Uploaded Photos (for Trash Threw)
                      if (!isPickup && photoPath.isNotEmpty) ...[
                        const Text(
                          'Uploaded Photos:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          photoPath.split('/').last,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.blue,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Location Address Box
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: (isPickup
                                  ? const Color(0xFF00A8E8)
                                  : const Color(0xFFFFA500))
                              .withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isPickup
                                ? const Color(0xFF00A8E8)
                                : const Color(0xFFFFA500),
                          ),
                        ),
                        child: Text(
                          'Location: $address',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black87,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Close Button
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isPickup
                          ? const Color(0xFF00A8E8)
                          : const Color(0xFFFFA500),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final bool isPickup;
  final String trashId;
  final String address;
  final DateTime? date;
  final String reportId;
  final String description;
  final String issueType;
  final String photoPath;
  final VoidCallback onTap;

  const _HistoryCard({
    required this.isPickup,
    required this.trashId,
    required this.address,
    required this.date,
    required this.reportId,
    required this.description,
    required this.issueType,
    required this.photoPath,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardColor =
        isPickup ? const Color(0xFF00A8E8) : const Color(0xFFFFA500);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardColor, width: 1.5),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Icon
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cardColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isPickup ? Icons.check_circle : Icons.delete,
                    color: cardColor,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),

                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isPickup ? 'Trash Pick-up' : 'Trash Threw',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        address,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[600],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Truck ID: $trashId',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                ),

                // Date and Arrow
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (date != null) ...[
                      Text(
                        DateFormat('MMMM dd, yyyy').format(date!),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        DateFormat('h:mm a').format(date!),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Trash ID: $trashId',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: Colors.grey[400],
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
