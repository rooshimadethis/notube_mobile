import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/feed_source.dart';
import 'feed_discovery.dart';

class SmallWebDiscovery {
  SmallWebDiscovery(this._client);

  static final _directory = Uri.parse(
    'https://raw.githubusercontent.com/kagisearch/smallweb/main/smallweb.txt',
  );
  static const _cacheKey = 'small_web_discovery';
  static const _batchSize = 5;
  static const _probeLimit = 12;
  static const _historyLimit = 150;

  final http.Client _client;
  Future<List<FeedSource>>? _pending;

  Future<List<FeedSource>> load({
    required DateTime now,
    required Set<String> excludedHosts,
  }) async {
    final pending = _pending ??= _load(now, excludedHosts);
    try {
      final batch = await pending;
      return batch.where((source) {
        return !excludedHosts.contains(publisherHost(source.url));
      }).toList();
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<List<FeedSource>> _load(
    DateTime now,
    Set<String> excludedHosts,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final cache = _DiscoveryCache.read(prefs.getString(_cacheKey));
    final day =
        DateTime.utc(now.year, now.month, now.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    if (cache.day == day) return cache.sources;

    final response = await readFeedPage(
      _client,
      _directory,
      maxBytes: 4 * 1024 * 1024,
      allowRedirect: (url) => url.origin == _directory.origin,
    );
    if (response == null) return cache.sources;

    final unavailable = {...excludedHosts, ...cache.recentHosts};
    final urls = const LineSplitter().convert(response.body)
      ..shuffle(Random(day));
    final probes = <Uri>[];
    final pickedHosts = <String>{};
    for (final line in urls) {
      final url = Uri.tryParse(line.trim());
      if (url == null || !_isPublisherUrl(url)) continue;
      final host = publisherHost(url.toString());
      if (unavailable.contains(host) || !pickedHosts.add(host)) continue;
      probes.add(url);
      if (probes.length == _probeLimit) break;
    }

    final discovery = FeedDiscovery(_client);
    final results = await Future.wait(
      probes.map(
        (url) => discovery.checkDirectoryFeed(url, allowUrl: _isPublisherUrl),
      ),
    );
    final batch = <FeedSource>[];
    final seen = <String>{};
    for (final source in results.whereType<FeedSource>()) {
      final host = publisherHost(source.url);
      if (unavailable.contains(host) || !seen.add(host)) continue;
      batch.add(
        FeedSource(
          title: source.title,
          url: source.url,
          category: 'Independent blogs',
          enabled: false,
        ),
      );
      if (batch.length == _batchSize) break;
    }
    if (batch.isEmpty) return cache.sources;

    // Update the batch and its history together so a restart can't reselect
    // publishers that were saved for display without also marking them as seen.
    await prefs.setString(
      _cacheKey,
      jsonEncode({
        'day': day,
        'sources': [
          for (final source in batch)
            {'title': source.title, 'url': source.url},
        ],
        'recentHosts': [
          ...seen,
          ...cache.recentHosts,
        ].take(_historyLimit).toList(),
      }),
    );
    return batch;
  }

  static String publisherHost(String url) =>
      (Uri.tryParse(url)?.host.toLowerCase() ?? '').replaceFirst(
        RegExp(r'^www\.'),
        '',
      );

  static final _publicHostname = RegExp(r'^[a-z0-9.-]+\.[a-z][a-z0-9-]*$');

  static bool _isPublisherUrl(Uri url) {
    final host = url.host.toLowerCase();
    return url.scheme == 'https' &&
        url.port == 443 &&
        url.userInfo.isEmpty &&
        _publicHostname.hasMatch(host) &&
        !const {
          'localhost',
          'local',
          'internal',
          'lan',
          'test',
          'home',
        }.contains(host.split('.').last) &&
        host != 'youtu.be' &&
        host != 'youtube.com' &&
        !host.endsWith('.youtube.com');
  }
}

class _DiscoveryCache {
  const _DiscoveryCache({
    this.day,
    this.sources = const [],
    this.recentHosts = const [],
  });

  final int? day;
  final List<FeedSource> sources;
  final List<String> recentHosts;

  factory _DiscoveryCache.read(String? value) {
    if (value == null) return const _DiscoveryCache();
    try {
      final data = jsonDecode(value);
      if (data is! Map<String, dynamic> ||
          data['day'] is! int ||
          data['sources'] is! List ||
          data['recentHosts'] is! List) {
        return const _DiscoveryCache();
      }
      return _DiscoveryCache(
        day: data['day'] as int,
        sources: [
          for (final entry in data['sources'] as List)
            if (entry case {
              'title': final String title,
              'url': final String url,
            })
              FeedSource(
                title: title,
                url: url,
                category: 'Independent blogs',
                enabled: false,
              ),
        ],
        recentHosts: (data['recentHosts'] as List).whereType<String>().toList(),
      );
    } on FormatException {
      return const _DiscoveryCache();
    }
  }
}
