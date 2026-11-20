import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notube_mobile/models/feed_source.dart';
import 'package:notube_mobile/services/feed_discovery.dart';
import 'package:notube_mobile/services/feed_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const source = FeedSource(
  title: 'Journal',
  url: 'https://example.com/feed',
  category: 'Science',
);

String rss([String items = '']) => '<rss><channel>$items</channel></rss>';

const article = '''
<item><title>Today in science</title><link>/today</link>
  <enclosure type="image/png" url="cover.png"/>
</item>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'all failed sources report an error; no followed sources is empty',
    () async {
      final service = FeedService.withClient(
        MockClient((_) async => http.Response('', 503)),
      );
      await expectLater(service.fetchFeeds([source]), throwsStateError);
      expect(await service.fetchFeeds([]), isEmpty);
    },
  );

  test('an unavailable source does not block another source', () async {
    final service = FeedService.withClient(
      MockClient((request) async {
        return request.url.path == '/feed'
            ? http.Response(rss(article), 200)
            : http.Response('', 503);
      }),
    );
    final items = await service.fetchFeeds([
      source,
      const FeedSource(
        title: 'Unavailable',
        url: 'https://example.com/unavailable',
        category: 'Science',
      ),
    ]);
    expect(items.single.title, 'Today in science');
  });

  test(
    'refresh keeps cache on failure and clears it on a valid empty feed',
    () async {
      var attempt = 0;
      final service = FeedService.withClient(
        MockClient((request) async {
          if (attempt > 0) expect(request.headers['if-none-match'], '"v1"');
          return switch (attempt++) {
            0 => http.Response(rss(article), 200, headers: {'etag': '"v1"'}),
            1 => http.Response('', 304),
            2 => http.Response('<html>Maintenance</html>', 200),
            3 => http.Response('', 503),
            4 => http.Response(rss(), 200, headers: {'etag': '"v2"'}),
            _ => throw StateError('Unexpected network request'),
          };
        }),
      );

      expect(
        (await service.fetchFeeds([source])).single.link,
        'https://example.com/today',
      );
      for (var i = 0; i < 3; i++) {
        expect(
          await service.fetchFeeds([source], forceRefresh: true),
          hasLength(1),
        );
      }
      expect(await service.fetchFeeds([source], forceRefresh: true), isEmpty);
      expect(await service.fetchFeeds([source]), isEmpty);
      expect(attempt, 5);
    },
  );

  test('overlapping refreshes share one request for the same feed', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    var requests = 0;
    final service = FeedService.withClient(
      MockClient((_) {
        if (++requests == 1) started.complete();
        return response.future;
      }),
    );
    final first = service.fetchFeeds([source]);
    await started.future;
    final second = service.fetchFeedsStream([source], forceRefresh: true);
    final both = second.toList();
    await Future<void>.delayed(Duration.zero);
    response.complete(http.Response(rss(article), 200));
    expect(await first, hasLength(1));
    expect((await both).last, hasLength(1));
    expect(requests, 1);
  });

  test(
    'prefixed Atom resolves links and images against the redirect target',
    () async {
      final service = FeedService.withClient(
        MockClient((request) async {
          if (request.url.path == '/feed') {
            return http.Response(
              '',
              302,
              headers: {'location': '/journal/feed.xml'},
            );
          }
          return http.Response('''
        <a:feed xmlns:a="http://www.w3.org/2005/Atom">
          <a:title>Science Journal</a:title>
          <a:entry>
            <a:title>Plants and light</a:title>
            <a:link href="posts/plants"/>
            <a:link rel="enclosure" type="image/png" href="plants.png"/>
          </a:entry>
        </a:feed>
      ''', 200);
        }),
      );
      final item = (await service.fetchFeeds([source])).single;
      expect(item.sourceUrl, source.url);
      expect(item.source, 'Science Journal');
      expect(item.link, 'https://example.com/journal/posts/plants');
      expect(item.imageUrl, 'https://example.com/journal/plants.png');
    },
  );

  test(
    'reads RSS 1.0 with arbitrary prefixes and items outside the channel',
    () async {
      final client = MockClient(
        (_) async => http.Response('''
      <r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
          xmlns:news="http://purl.org/rss/1.0/">
        <news:channel><news:title>RDF Journal</news:title></news:channel>
        <news:item><news:title>Plants and light</news:title>
          <news:link>/plants</news:link></news:item>
      </r:RDF>
    ''', 200),
      );
      final discovery = FeedDiscovery(client);
      final found = await discovery.checkDirectoryFeed(
        Uri.parse(source.url),
        allowUrl: (_) => true,
      );
      expect(found?.title, 'RDF Journal');
      final items = await FeedService.withClient(client).fetchFeeds([found!]);
      expect(items.single.link, 'https://example.com/plants');
    },
  );

  test('oversized responses are discarded', () async {
    final client = MockClient((_) async => http.Response('0123456789', 200));
    final result = await readFeedPage(
      client,
      Uri.parse(source.url),
      maxBytes: 9,
    );
    expect(result, isNull);
  });
}
