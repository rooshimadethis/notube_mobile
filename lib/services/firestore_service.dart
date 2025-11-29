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
          final parsed = alts.map((e) => Alternative()..mergeFromProto3Json(e)).toList();
          developer.log("Fetched ${parsed.length} alternatives from Firestore for user $userId");
          return parsed;
        }
      }
      developer.log("No alternatives found for user $userId");
      return [];
    } catch (e) {
      developer.log("Error fetching alternatives: $e");
      rethrow;
    }
  }

  Future<void> saveUserAlternatives(
      String userId, List<Alternative> alternatives) async {
    try {
      // Convert to Map explicitly to ensure field names are strings (not proto tags)
      final altsData = alternatives.map(_alternativeToMap).toList();
      
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
  /// Used when the user chooses to "Merge" in the sync dialog.
  /// Cloud items take precedence for conflicts (same URL/Title).
  /// Local items are added only if they are not present in the cloud list.
  List<Alternative> mergeAlternatives(
      List<Alternative> local, List<Alternative> cloud) {
    final Map<String, Alternative> mergedMap = {};

    // 1. Add all cloud items (they win conflicts)
    for (var item in cloud) {
      final key = item.url.isNotEmpty ? item.url : item.title;
      if (key.isNotEmpty) {
        mergedMap[key] = item;
      } else {
        // If absolutely no identifier, keep it (using hash as temporary key)
        mergedMap['cloud_${item.hashCode}'] = item;
      }
    }

    // 2. Add local items only if they don't exist in cloud
    for (var item in local) {
      final key = item.url.isNotEmpty ? item.url : item.title;
      if (key.isNotEmpty) {
         if (!mergedMap.containsKey(key)) {
           mergedMap[key] = item;
         }
      }
      // If local item has no identifier, we skip it to avoid duplicates/garbage
    }

    return mergedMap.values.toList();
  }

  Future<void> removeAlternative(String userId, Alternative alternative) async {
    try {
      await _db.collection('users').doc(userId).update({
        'alternatives': FieldValue.arrayRemove([_alternativeToMap(alternative)])
      });
      developer.log("Removed alternative from Firestore for user $userId");
    } catch (e) {
      developer.log("Error removing alternative: $e");
      rethrow;
    }
  }

  Future<void> addAlternative(String userId, Alternative alternative) async {
    try {
      await _db.collection('users').doc(userId).set({
        'alternatives': FieldValue.arrayUnion([_alternativeToMap(alternative)]),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      developer.log("Added alternative to Firestore for user $userId");
    } catch (e) {
      developer.log("Error adding alternative: $e");
      rethrow;
    }
  }

  Map<String, dynamic> _alternativeToMap(Alternative a) {
    return {
      'title': a.title,
      'url': a.url,
      'description': a.description,
      'category': a.category,
      'bypassPaywall': a.bypassPaywall,
    };
  }
}