import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notube_mobile/models/feed_item.dart';
import 'package:notube_mobile/models/feed_source.dart';
import 'package:notube_mobile/services/feed_discovery.dart';
import 'package:notube_mobile/services/feed_service.dart';
import 'package:notube_mobile/services/reading_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mixed batches rotate categories and exclude already shown links', () {
    final now = DateTime.utc(2026, 11, 20);
    FeedItem item(
      String id,
      String publisher,
      String category,
      int age, {
      String? link,
    }) {
      return FeedItem(
        title: id,
        link: link ?? 'https://example.com/$id',
        description: '',
        source: publisher,
        sourceUrl: 'https://$publisher.example/feed',
        category: category,
        publishedDate: now.subtract(Duration(days: age)),
      );
    }

    final read = item('read', 'science', 'Science', 0);
    final video = item(
      'video',
      'video',
      'Video',
      0,
      link: 'https://youtu.be/example',
    );
    final archive = item('archive', 'nature', 'Science', 60);
    final followed = [
      for (var index = 0; index < 16; index++)
        item(
          'recent-$index',
          'publisher-$index',
          index.isEven ? 'Tech News' : 'Machine Learning',
          2,
        ),
      item('science', 'science', 'Science', 4),
      item('design', 'design', 'Design', 5),
      ...List.generate(
        3,
        (index) => item('same-$index', 'science', 'Science', 6),
      ),
      archive,
    ];
    final candidates = [read, video, ...followed, followed.first];
    final first = buildReadingList(
      candidates,
      isRead: (link) => link == read.link,
      now: now,
    );
    expect(first, hasLength(readingListLength));
    expect(first.take(3).map((article) => article.category), [
      'Tech News',
      'Science',
      'Design',
    ]);
    expect(first, isNot(contains(video)));
    expect(first, contains(archive));
    expect(
      first.where((article) => article.source == 'science').length,
      lessThanOrEqualTo(2),
    );
    final shown = {read.link, ...first.map((article) => article.link)};
    final second = buildReadingList(
      candidates,
      isRead: shown.contains,
      now: now,
    );
    expect(second, isNotEmpty);
    expect(second.where((article) => shown.contains(article.link)), isEmpty);
  });

  test(
    'finds and verifies advertised RSS and Atom without returning HTML',
    () async {
      final client = MockClient((request) async {
        return switch (request.url.path) {
          '/start' => http.Response(
            '',
            302,
            headers: {'location': '/journal/'},
          ),
          '/journal/' => http.Response('''
          <!-- <link rel=alternate type=application/rss+xml href=/comment> -->
          <link href="../rss?type=all&amp;limit=10" type="application/rss+xml" rel="alternate">
          <link rel=alternate href=/atom type=application/atom+xml>
          <link rel=alternate href=/not-feed type=application/rss+xml>
        ''', 200),
          '/rss' => http.Response(
            '<rss><channel><title>RSS Journal</title></channel></rss>',
            200,
          ),
          '/atom' => http.Response(
            '<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Journal</title></feed>',
            200,
          ),
          '/not-feed' => http.Response('<html></html>', 200),
          _ => throw StateError('Unexpected discovery request'),
        };
      });
      final discovery = FeedDiscovery(client);
      final results = await discovery.find('example.com/start');
      expect(results.map((source) => source.title), [
        'RSS Journal',
        'Atom Journal',
      ]);
      expect(results.first.url, 'https://example.com/rss?type=all&limit=10');
      expect(
        (await discovery.find('https://example.com/atom')).single.title,
        'Atom Journal',
      );
      await expectLater(
        discovery.find('file:///local/feed.xml'),
        throwsFormatException,
      );
    },
  );

  test(
    'persists followed custom sources and respects explicit hides',
    () async {
      SharedPreferences.setMockInitialValues({
        'feed_preferences': '{"http://www.quantamagazine.org/feed/":false}',
      });
      final service = FeedService();
      const custom = FeedSource(
        title: 'My Journal',
        url: 'https://example.com/journal.xml',
        category: 'My sources',
      );
      await Future.wait([
        service.followSource(custom),
        service.followSource(custom),
      ]);
      final sources = await service.loadFeedSources();
      expect(sources.where((source) => source == custom), hasLength(1));
      final quanta = sources.singleWhere(
        (source) => source.title == 'Quanta Magazine',
      );
      final suggested = sources.firstWhere((source) => source.suggested);
      final initialPreferences = await service.getFeedPreferences();
      expect(
        service.isDiscoverableSource(suggested, initialPreferences),
        isTrue,
      );
      expect(service.isDiscoverableSource(quanta, initialPreferences), isFalse);
      await service.followSource(suggested);
      final afterFollow = await service.getFeedPreferences();
      expect(service.isFeedEnabled(suggested, afterFollow), isTrue);
      expect(service.isDiscoverableSource(suggested, afterFollow), isFalse);
      await service.disableFeedSource(suggested.url);
      final preferences = await service.getFeedPreferences();
      expect(service.isFeedEnabled(quanta, preferences), isFalse);
      expect(service.isFeedEnabled(custom, preferences), isTrue);
      expect(service.isSuggestedSource(suggested, preferences), isFalse);
      expect(service.isDiscoverableSource(suggested, preferences), isFalse);
    },
  );
}
