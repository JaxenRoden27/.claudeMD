import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Example: Add a new document
  Future<void> addSampleData(String name) async {
    try {
      await _db.collection('samples').add({
        'name': name,
        'timestamp': FieldValue.serverTimestamp(),
      });
      print('Data added successfully');
    } catch (e) {
      print('Error adding data: $e');
    }
  }

  // Example: Stream of data
  Stream<QuerySnapshot> getSamples() {
    return _db.collection('samples').snapshots();
  }
}
