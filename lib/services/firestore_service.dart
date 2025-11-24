import 'dart:developer' as developer;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:notube_shared/alternative.pb.dart';

class FirestoreService {
  FirebaseFirestore get _db => FirebaseFirestore.instance;

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
      developer.log("Error fetching alternatives: $e");
      return [];
    }
  }

  Future<void> saveUserAlternatives(
      String userId, List<Alternative> alternatives) async {
    try {
      final altsData = alternatives.map((a) => a.writeToJsonMap()).toList();
      
      await _db.collection('users').doc(userId).set({
        'alternatives': altsData,
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      developer.log("Error saving alternatives: $e");
      rethrow;
    }
  }

  /// Merges local and cloud alternatives.
  /// Cloud items take precedence. Local items are added only if they are new.
  List<Alternative> mergeAlternatives(
      List<Alternative> local, List<Alternative> cloud) {
    final Map<String, Alternative> mergedMap = {};

    // 1. Add all cloud items (they win conflicts)
    for (var item in cloud) {
      if (item.url.isNotEmpty) {
        mergedMap[item.url] = item;
      }
    }

    // 2. Add local items only if they don't exist in cloud
    for (var item in local) {
      if (item.url.isNotEmpty && !mergedMap.containsKey(item.url)) {
        mergedMap[item.url] = item;
      }
    }

    return mergedMap.values.toList();
  }
}