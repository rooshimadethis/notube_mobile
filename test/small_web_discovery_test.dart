import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notube_mobile/services/feed_service.dart';
import 'package:notube_mobile/services/small_web_discovery.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'uses the live directory, keeps a daily batch, and skips recent publishers',
    () async {
      SharedPreferences.setMockInitialValues({});
      final requests = <Uri>[];
      final urls = [
        for (var i = 0; i < 8; i++) 'https://blog$i.example/feed',
        'https://known.example/feed',
        'https://www.known.example/feed',
        'https://bad.example/feed',
        'https://redirect.example/feed',
        'https://127.0.0.1/feed',
        'https://www.youtube.com/feed',
        'https://service.internal/feed',
      ];
      var offline = false;
      final client = MockClient((request) async {
        final url = request.url;
        requests.add(url);
        if (url.host == 'raw.githubusercontent.com') {
          return offline
              ? http.Response('', 503)
              : http.Response(urls.join('\n'), 200);
        }
        if (url.host == 'bad.example') {
          return http.Response('<html></html>', 200);
        }
        if (url.host == 'redirect.example') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://127.0.0.1/feed'},
          );
        }
        expect(url.host, startsWith('blog'));
        return http.Response(
          '<rss><channel><title>Publisher $url</title><item><title>Article</title>'
          '<link>https://${url.host}/article</link></item></channel></rss>',
          200,
        );
      });

      final firstDay = DateTime(2026, 11, 20);
      final known = {'known.example'};
      final discovery = SmallWebDiscovery(client);
      final concurrent = await Future.wait([
        discovery.load(now: firstDay, excludedHosts: known),
        discovery.load(now: firstDay, excludedHosts: known),
      ]);
      final first = concurrent.first;
      expect(first, hasLength(5));
      expect(concurrent.last, first);
      expect(
        requests.where((url) => url.host == 'raw.githubusercontent.com'),
        hasLength(1),
      );
      expect(
        first.every((source) => source.title.startsWith('Publisher ')),
        isTrue,
      );
      expect(first.every((source) => !source.enabled), isTrue);

      final followed = SmallWebDiscovery.publisherHost(first.first.url);
      final feeds = FeedService();
      await feeds.followSource(first.first);
      final savedPublisher = (await feeds.loadFeedSources()).singleWhere(
        (source) => source.url == first.first.url,
      );
      expect(
        feeds.isFeedEnabled(savedPublisher, await feeds.getFeedPreferences()),
        isTrue,
      );
      final requestCount = requests.length;
      final restarted = SmallWebDiscovery(client);
      final sameDay = await restarted.load(
        now: firstDay,
        excludedHosts: {...known, followed},
      );
      expect(sameDay, first.skip(1).toList());
      expect(requests, hasLength(requestCount));

      urls.add('https://blog9.example/feed');
      final second = await restarted.load(
        now: DateTime(2026, 11, 21),
        excludedHosts: known,
      );
      expect(second, hasLength(4));
      expect(second.where(first.contains), isEmpty);
      expect(
        second.any((source) => source.url == 'https://blog9.example/feed'),
        isTrue,
      );

      offline = true;
      final cached = await restarted.load(
        now: DateTime(2026, 11, 22),
        excludedHosts: known,
      );
      expect(cached, second);
    },
  );
}
