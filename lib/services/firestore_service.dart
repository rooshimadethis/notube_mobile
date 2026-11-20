import 'dart:developer' as developer;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:notube_shared/alternative.pb.dart';

class FirestoreService {
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  Future<List<Alternative>?> getUserAlternatives(String userId) async {
    final doc = await _db.collection('users').doc(userId).get();
    return _readAlternatives(doc);
  }

  List<Alternative>? _readAlternatives(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final stored = doc.data()?['alternatives'] as List<dynamic>?;
    return stored?.map((e) => Alternative()..mergeFromProto3Json(e)).toList();
  }

  Future<List<Alternative>> initializeUserAlternatives(
    String userId,
    List<Alternative> local,
  ) => _updateAlternatives(userId, local, merge: false);

  Future<List<Alternative>> mergeUserAlternatives(
    String userId,
    List<Alternative> local,
  ) => _updateAlternatives(userId, local, merge: true);

  Future<List<Alternative>> _updateAlternatives(
    String userId,
    List<Alternative> local, {
    required bool merge,
  }) {
    final doc = _db.collection('users').doc(userId);
    // Another device can write after the initial load or while the dialog is open.
    return _db.runTransaction((transaction) async {
      final cloud = _readAlternatives(await transaction.get(doc));
      if (cloud != null && !merge) return cloud;

      final updated = cloud == null ? local : mergeAlternatives(local, cloud);
      transaction.set(doc, {
        'alternatives': updated.map(_alternativeToMap).toList(),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return updated;
    });
  }

  /// Merges local and cloud alternatives.
  /// Used when the user chooses to "Merge" in the sync dialog.
  /// Cloud items take precedence for conflicts (same URL/Title).
  /// Local items are added only if they are not present in the cloud list.
  List<Alternative> mergeAlternatives(
    List<Alternative> local,
    List<Alternative> cloud,
  ) {
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
        'alternatives': FieldValue.arrayRemove([
          _alternativeToMap(alternative),
        ]),
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
