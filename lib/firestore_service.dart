import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Example: Add a new document
  Future<void> addSampleData(String name) async {
    try {
      await _db.collection('samples').add({
        'name': name,
        'timestamp': FieldValue.serverTimestamp(),
      });
      if (kDebugMode) {
        debugPrint('Data added successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error adding data: $e');
      }
      rethrow;
    }
  }

  // Example: Stream of data
  Stream<QuerySnapshot> getSamples() {
    return _db.collection('samples').snapshots();
  }
}
