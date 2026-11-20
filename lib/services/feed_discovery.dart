import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/feed_source.dart';

Future<({Uri url, http.StreamedResponse response})> requestFeedUrl(
  http.Client client,
  Uri address, {
  Map<String, String> headers = const {},
  Future<void>? abortTrigger,
  bool Function(Uri)? allowRedirect,
}) async {
  var url = address;
  for (var redirects = 0; ; redirects++) {
    final request =
        http.AbortableRequest('GET', url, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers.addAll(headers);
    final response = await client.send(request);
    final location = response.headers['location'];
    if (location == null ||
        !const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
      return (url: url, response: response);
    }
    await response.stream.drain<void>();

    // Resolve each hop so relative feed and article links use the final page URL.
    final target = url.resolve(location);
    if (redirects == 5 ||
        !_isWebUrl(target) ||
        allowRedirect?.call(target) == false) {
      throw const FormatException('Invalid feed redirect.');
    }
    url = target;
  }
}

bool _isWebUrl(Uri url) =>
    (url.scheme == 'https' || url.scheme == 'http') &&
    url.host.isNotEmpty &&
    url.userInfo.isEmpty;

class FeedDiscovery {
  FeedDiscovery(this._client);

  final http.Client _client;

  static final _linkTag = RegExp(
    r'''<!--[\s\S]*?-->|<link(?=\s|/?>)(?:[^>"']|"[^"]*"|'[^']*')*>''',
    caseSensitive: false,
  );
  static final _attribute = RegExp(
    r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
  );

  Future<List<FeedSource>> find(String input) async {
    final value = input.trim();
    final address = Uri.tryParse(
      value.contains('://') ? value : 'https://$value',
    );
    if (value.isEmpty || address == null || !_isWebUrl(address)) {
      throw const FormatException('Enter a website or feed URL.');
    }

    final page = await readFeedPage(_client, address.removeFragment());
    if (page == null) {
      throw const FormatException(
        'Couldn’t open that address. Check the URL and try again.',
      );
    }
    final direct = _readFeed(page);
    if (direct != null) return [direct];

    final candidates = <Uri>{};
    for (final tag in _linkTag.allMatches(page.body)) {
      final markup = tag.group(0)!;
      if (markup.startsWith('<!--')) continue;
      final attributes = <String, String>{
        for (final match in _attribute.allMatches(markup))
          match.group(1)!.toLowerCase():
              (match.group(2) ?? match.group(3) ?? match.group(4)!).trim(),
      };
      final rel = attributes['rel']?.toLowerCase().split(RegExp(r'\s+'));
      final type = attributes['type']?.toLowerCase().split(';').first.trim();
      final href = attributes['href'];
      if (rel?.contains('alternate') != true ||
          (type != 'application/rss+xml' && type != 'application/atom+xml') ||
          href == null ||
          href.isEmpty) {
        continue;
      }
      final reference = Uri.tryParse(href.replaceAll('&amp;', '&'));
      if (reference == null) continue;
      final candidate = page.url.resolveUri(reference).removeFragment();
      if (_isWebUrl(candidate)) candidates.add(candidate);
      if (candidates.length == 5) break;
    }

    final results = await Future.wait(
      candidates.map((url) async {
        final response = await readFeedPage(_client, url);
        return response == null ? null : _readFeed(response);
      }),
    );
    return results.whereType<FeedSource>().toSet().toList();
  }

  Future<FeedSource?> checkDirectoryFeed(
    Uri url, {
    required bool Function(Uri) allowUrl,
  }) async {
    if (!allowUrl(url)) return null;
    final result = await readFeedPage(
      _client,
      url,
      allowRedirect: allowUrl,
      timeout: const Duration(seconds: 5),
    );
    return result == null ? null : _readFeed(result, requireArticles: true);
  }

  static FeedSource? _readFeed(
    ({Uri url, String body}) page, {
    bool requireArticles = false,
  }) {
    try {
      final root = XmlDocument.parse(page.body).rootElement;
      final XmlElement? feed = switch (root.name.local) {
        'rss' || 'RDF' => root.findElements('channel').firstOrNull,
        'feed' => root,
        _ => null,
      };
      if (feed == null) return null;
      if (requireArticles &&
          root
              .findAllElements(root.name.local == 'feed' ? 'entry' : 'item')
              .isEmpty) {
        return null;
      }
      final title = feed.childElements
          .where((element) => element.name.local == 'title')
          .firstOrNull
          ?.innerText
          .trim();
      return FeedSource(
        title: title == null || title.isEmpty ? page.url.host : title,
        url: page.url.toString(),
        category: 'My sources',
      );
    } on XmlException {
      return null;
    }
  }
}

Future<({Uri url, String body})?> readFeedPage(
  http.Client client,
  Uri address, {
  int maxBytes = 2 * 1024 * 1024,
  Duration timeout = const Duration(seconds: 8),
  bool Function(Uri)? allowRedirect,
}) async {
  final abort = Completer<void>();
  void cancel() {
    if (!abort.isCompleted) abort.complete();
  }

  // Bound the whole request, including redirects and response body downloads.
  final deadline = Timer(timeout, cancel);
  try {
    final (:url, :response) = await requestFeedUrl(
      client,
      address,
      abortTrigger: abort.future,
      allowRedirect: allowRedirect,
      headers: const {
        'Accept':
            'application/atom+xml,application/rss+xml,text/html,application/xml,*/*;q=0.8',
      },
    );
    if (response.statusCode != 200) {
      cancel();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxBytes) {
        cancel();
        return null;
      }
      bytes.addAll(chunk);
    }
    return (
      url: url.removeFragment(),
      body: utf8.decode(bytes, allowMalformed: true),
    );
  } on Exception {
    return null;
  } finally {
    deadline.cancel();
  }
}
