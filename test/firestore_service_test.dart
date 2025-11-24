import 'package:flutter_test/flutter_test.dart';
import 'package:notube_mobile/services/firestore_service.dart';
import 'package:notube_shared/alternative.pb.dart';

void main() {
  group('FirestoreService Merge Logic', () {
    final service = FirestoreService();

    test('Cloud item should persist if local is empty', () {
      final cloud = [Alternative()..url = 'http://cloud.com'..title = 'Cloud'];
      final local = <Alternative>[];

      final result = service.mergeAlternatives(local, cloud);

      expect(result.length, 1);
      expect(result.first.title, 'Cloud');
    });

    test('Local item should persist if cloud is empty', () {
      final cloud = <Alternative>[];
      final local = [Alternative()..url = 'http://local.com'..title = 'Local'];

      final result = service.mergeAlternatives(local, cloud);

      expect(result.length, 1);
      expect(result.first.title, 'Local');
    });

    test('Cloud item should overwrite local item if URLs match', () {
      final cloud = [Alternative()..url = 'http://same.com'..title = 'Cloud Version'];
      final local = [Alternative()..url = 'http://same.com'..title = 'Local Version'];

      final result = service.mergeAlternatives(local, cloud);

      expect(result.length, 1);
      expect(result.first.title, 'Cloud Version'); // This confirms the fix
    });

    test('Should merge unique items from both', () {
      final cloud = [Alternative()..url = 'http://cloud.com'..title = 'Cloud'];
      final local = [Alternative()..url = 'http://local.com'..title = 'Local'];

      final result = service.mergeAlternatives(local, cloud);

      expect(result.length, 2);
      expect(result.any((a) => a.title == 'Cloud'), isTrue);
      expect(result.any((a) => a.title == 'Local'), isTrue);
    });
  });
}
