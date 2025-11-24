import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:notube_shared/alternative.pb.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<List<Alternative>> getUserAlternatives(String userId) async {
    try {
      DocumentSnapshot doc = await _db.collection('users').doc(userId).get();

      if (doc.exists && doc.data() != null) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        if (data.containsKey('alternatives')) {
          List<dynamic> alts = data['alternatives'];
          return alts.map((e) => Alternative()..mergeFromJsonMap(e)).toList();
        }
      }
      return [];
    } catch (e) {
      print("Error fetching alternatives: $e");
      return [];
    }
  }
}
