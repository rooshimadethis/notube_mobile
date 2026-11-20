import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sentiment_dart/sentiment_dart.dart';
// import 'package:ml_sentiment_simple/ml_sentiment_simple.dart';
import 'package:xml/xml.dart';

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

// import 'sentiment_ai_service.dart'; // Disabled - native library issues
import '../models/feed_item.dart';
import '../models/feed_source.dart';
import '../models/feed_cache.dart';
import 'feed_discovery.dart';
import 'small_web_discovery.dart';

class FeedService {
  static final FeedService _instance = FeedService._internal();
  factory FeedService() => _instance;
  FeedService._internal() : _client = http.Client();

  @visibleForTesting
  FeedService.withClient(this._client);

  final http.Client _client;
  late final _smallWeb = SmallWebDiscovery(_client);
  // final SentimentAiService _aiService = SentimentAiService(); // Disabled
  // bool _aiInitialized = false; // Disabled

  // Cache for feed URLs to avoid re-parsing OPML constantly if not needed
  // But for now we just load every time or rely on caller to manage state

  static const String _feedPreferencesKey = 'feed_preferences';
  static const String _customSourcesKey = 'custom_feed_sources';
  static const _previousFeedUrls = {
    'https://www.quantamagazine.org/feed/':
        'http://www.quantamagazine.org/feed/',
    'https://news.ycombinator.com/rss': 'http://news.ycombinator.com/rss',
  };
  Future<void> _sourceWrites = Future.value();
  static const String _readArticlesKey = 'read_articles';

  // Limit strictly to keep 'markArticleAsRead' fast (disk write on every tap).
  // 2000 is safe because RSS feeds usually rotate content (drop old items)
  // much faster than a user reads 2000 items.
  static const int _maxReadHistory = 2000;

  // Cache for feed items: URL -> Cache Entry
  final Map<String, FeedCacheEntry> _cache = {};
  final Map<String, Future<void>> _pendingFetches = {};

  final Set<String> _readArticleUrls = {};
  bool _readArticlesLoaded = false;

  // Smart TTL: Check for updates after 1 hour.
  // Since we use Conditional GETs (ETag), checks are cheap!
  static const Duration _cacheTtl = Duration(hours: 1);

  Future<void> loadReadArticles() async {
    if (_readArticlesLoaded) return;

    final prefs = await SharedPreferences.getInstance();
    final List<String>? saved = prefs.getStringList(_readArticlesKey);
    if (saved != null) {
      _readArticleUrls.addAll(saved);
    }
    _readArticlesLoaded = true;
  }

  Future<void> markArticleAsRead(String url) async {
    if (!_readArticlesLoaded) await loadReadArticles();

    if (_readArticleUrls.contains(url)) return; // Already read

    _readArticleUrls.add(url);

    // Enforce max history size (FIFO)
    if (_readArticleUrls.length > _maxReadHistory) {
      final first = _readArticleUrls.first;
      _readArticleUrls.remove(first);
    }

    // Save to disk
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_readArticlesKey, _readArticleUrls.toList());
  }

  Future<void> markArticleAsUnread(String url) async {
    if (!_readArticlesLoaded) await loadReadArticles();

    if (!_readArticleUrls.contains(url)) return; // Already unread

    _readArticleUrls.remove(url);

    // Save to disk
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_readArticlesKey, _readArticleUrls.toList());
  }

  Future<List<FeedSource>> loadFeedSources() async {
    final sources = <FeedSource>{};
    try {
      // Load feeds.opml
      final feedsOpml = await rootBundle.loadString('feeds.opml');
      sources.addAll(_parseOpml(feedsOpml));
    } catch (e) {
      developer.log("Error loading OPML assets: $e");
    }
    sources.addAll(await _loadCustomSources());
    return sources.toList();
  }

  Future<List<FeedSource>> _loadCustomSources() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_customSourcesKey) ?? [];
    final sources = <FeedSource>[];
    for (final entry in saved) {
      try {
        final value = jsonDecode(entry) as Map<String, dynamic>;
        sources.add(
          FeedSource(
            title: value['title'] as String,
            url: value['url'] as String,
            category: 'My sources',
          ),
        );
      } on Exception {
        continue;
      } on TypeError {
        continue;
      }
    }
    return sources;
  }

  Future<List<FeedSource>> discoverFeeds(String address) =>
      FeedDiscovery(_client).find(address);

  Future<List<FeedSource>> loadSmallWebSources() async {
    final known = await loadFeedSources();
    final preferences = await getFeedPreferences();
    return _smallWeb.load(
      now: DateTime.now(),
      excludedHosts: {
        ...known.map((source) => SmallWebDiscovery.publisherHost(source.url)),
        ...preferences.keys.map(SmallWebDiscovery.publisherHost),
      },
    );
  }

  Future<void> followSource(FeedSource source) => _writeSources(() async {
    final known = await loadFeedSources();
    if (!known.contains(source)) {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_customSourcesKey) ?? [];
      final didSave = await prefs.setStringList(_customSourcesKey, [
        ...saved,
        jsonEncode({'title': source.title, 'url': source.url}),
      ]);
      if (!didSave) throw StateError('Couldn’t save the source.');
      return;
    }
    await _setFeedEnabled(source.url, true);
  });

  // Returns Map<Url, IsEnabled>
  Future<Map<String, bool>> getFeedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_feedPreferencesKey);
    if (jsonString == null) return {};

    try {
      final Map<String, dynamic> jsonMap = jsonDecode(jsonString);
      return jsonMap.map((key, value) => MapEntry(key, value as bool));
    } catch (e) {
      developer.log("Error parsing feed preferences: $e");
      return {};
    }
  }

  Future<void> _savePreferences(Map<String, bool> preferences) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_feedPreferencesKey, jsonEncode(preferences))) {
      throw StateError('Couldn’t save source preferences.');
    }
  }

  Future<void> _writeSources(Future<void> Function() write) {
    // Each change must see the preceding write, even when switches are tapped quickly.
    final pending = _sourceWrites.then((_) => write());
    _sourceWrites = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  Future<void> updateFeedEnabledState(String url, bool isEnabled) =>
      _writeSources(() => _setFeedEnabled(url, isEnabled));

  Future<void> _setFeedEnabled(String url, bool isEnabled) async {
    final prefs = await getFeedPreferences();
    prefs[url] = isEnabled;
    await _savePreferences(prefs);
  }

  Future<void> disableFeedSource(String url) async {
    await updateFeedEnabledState(url, false);
  }

  bool isFeedEnabled(FeedSource source, Map<String, bool> preferences) {
    return preferences[source.url] ??
        preferences[_previousFeedUrls[source.url]] ??
        source.enabled;
  }

  bool isSuggestedSource(FeedSource source, Map<String, bool> preferences) =>
      source.suggested && isDiscoverableSource(source, preferences);

  bool isDiscoverableSource(FeedSource source, Map<String, bool> preferences) {
    // Explicitly hidden sources stay in Settings so discovery doesn't suggest them again.
    final host = Uri.tryParse(source.url)?.host ?? '';
    return !isFeedEnabled(source, preferences) &&
        !preferences.containsKey(source.url) &&
        !preferences.containsKey(_previousFeedUrls[source.url]) &&
        host != 'youtube.com' &&
        !host.endsWith('.youtube.com');
  }

  List<FeedSource> _parseOpml(String opmlContent) {
    final List<FeedSource> sources = [];
    try {
      final document = XmlDocument.parse(opmlContent);
      final outlines = document.findAllElements('outline');

      for (var node in outlines) {
        final type = node.getAttribute('type');
        final xmlUrl = node.getAttribute('xmlUrl');
        final title =
            node.getAttribute('title') ??
            node.getAttribute('text') ??
            'Unknown Config';
        final category = node.getAttribute('category') ?? 'Uncategorized';
        final enabledStr = node.getAttribute('enabled');
        final isEnabled =
            enabledStr?.toLowerCase() !=
            'false'; // Default to true if missing or not false

        if (type == 'rss' && xmlUrl != null && xmlUrl.isNotEmpty) {
          // Generate favicon URL
          String? iconUrl;
          try {
            final uri = Uri.parse(xmlUrl);
            // Google Favicon Service: https://www.google.com/s2/favicons?domain=example.com&sz=64
            if (uri.host.isNotEmpty) {
              iconUrl =
                  'https://www.google.com/s2/favicons?domain=${uri.host}&sz=64';
            }
          } catch (_) {
            // Ignore parse errors, just no icon
          }

          sources.add(
            FeedSource(
              title: title,
              url: xmlUrl,
              category: category,
              enabled: isEnabled,
              suggested: node.getAttribute('suggested') == 'true',
              iconUrl: iconUrl,
            ),
          );
        }
      }
    } catch (e) {
      developer.log("Error parsing OPML: $e");
    }
    return sources;
  }

  bool isArticleRead(String url) {
    if (!_readArticlesLoaded) return false;
    return _readArticleUrls.contains(url);
  }

  Stream<List<FeedItem>> fetchFeedsStream(
    List<FeedSource> sources, {
    bool forceRefresh = false,
  }) {
    final controller = StreamController<List<FeedItem>>();
    // Start fetching without awaiting, so we return the stream immediately
    _startStreamFetching(sources, forceRefresh, controller);
    return controller.stream;
  }

  Future<void> _startStreamFetching(
    List<FeedSource> sources,
    bool forceRefresh,
    StreamController<List<FeedItem>> controller,
  ) async {
    try {
      await loadReadArticles();

      List<FeedItem> cachedItems() {
        final items = [
          for (final source in sources) ...?_cache[source.url]?.items,
        ];
        _sortItems(items);
        return items;
      }

      // Display stale entries during revalidation and keep them on failure.
      controller.add(cachedItems());
      final results = await Future.wait(
        sources.map((source) async {
          final cached = _cache[source.url];
          if (!forceRefresh &&
              cached != null &&
              DateTime.now().difference(cached.timestamp) < _cacheTtl) {
            return true;
          }
          try {
            await _refreshSource(source);
            if (!controller.isClosed) controller.add(cachedItems());
            return true;
          } catch (error) {
            developer.log('Error refreshing ${source.title}: $error');
            return _cache.containsKey(source.url);
          }
        }),
      );

      if (results.isNotEmpty && !results.contains(true)) {
        throw StateError('Couldn’t load any followed feeds.');
      }
    } catch (error, stack) {
      if (!controller.isClosed) controller.addError(error, stack);
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  Future<void> _refreshSource(FeedSource source) {
    // An overlapping check must not replace newer items using old validators.
    return _pendingFetches.putIfAbsent(
      source.url,
      () => _fetchAndUpdateCache(source).whenComplete(() {
        _pendingFetches.remove(source.url);
      }),
    );
  }

  void _sortItems(List<FeedItem> items) {
    items.sort((a, b) {
      if (a.publishedDate == null && b.publishedDate == null) return 0;
      if (a.publishedDate == null) return 1;
      if (b.publishedDate == null) return -1;
      return b.publishedDate!.compareTo(a.publishedDate!);
    });
  }

  Future<List<FeedItem>> fetchFeeds(
    List<FeedSource> sources, {
    bool forceRefresh = false,
  }) => fetchFeedsStream(sources, forceRefresh: forceRefresh).last;

  Future<void> _fetchAndUpdateCache(FeedSource source) async {
    final cached = _cache[source.url];
    final result = await _fetchFeed(
      source,
      etag: cached?.etag,
      lastModified: cached?.lastModified,
    );

    if (result.status == FetchStatus.notModified && cached != null) {
      _cache[source.url] = FeedCacheEntry(
        items: cached.items,
        timestamp: DateTime.now(),
        etag: cached.etag,
        lastModified: cached.lastModified,
      );
    } else if (result.status == FetchStatus.success) {
      // A valid but empty feed must clear articles from the previous version.
      _cache[source.url] = FeedCacheEntry(
        items: result.items,
        timestamp: DateTime.now(),
        etag: result.etag,
        lastModified: result.lastModified,
      );
    } else {
      throw StateError('No usable response for ${source.title}.');
    }
  }

  Future<FetchResult> _fetchFeed(
    FeedSource source, {
    String? etag,
    String? lastModified,
  }) async {
    try {
      final headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Upgrade-Insecure-Requests': '1',
      };

      if (etag != null) headers['If-None-Match'] = etag;
      if (lastModified != null) headers['If-Modified-Since'] = lastModified;

      final fetch = await readFeedResponse(
        _client,
        Uri.parse(source.url),
        headers: headers,
        timeout: const Duration(seconds: 10),
        maxBytes: 8 * 1024 * 1024,
      );
      if (fetch == null) return FetchResult.error();
      final (url: baseUrl, :response) = fetch;

      if (response.statusCode == 304) {
        return FetchResult.notModified();
      } else if (response.statusCode == 200) {
        final items = await compute(_parseAndFilterFeed, {
          'xml': _decodeFeed(response),
          'url': source.url,
          'baseUrl': baseUrl,
          'category': source.category,
          'iconUrl': source.iconUrl,
        });

        return FetchResult.success(
          items: items,
          etag: response.headers['etag'],
          lastModified: response.headers['last-modified'],
        );
      } else {
        developer.log(
          "Failed to fetch feed ${source.url}: ${response.statusCode}",
        );
      }
    } catch (e) {
      developer.log("Error fetching feed ${source.url}: $e");
    }
    return FetchResult.error();
  }
}

String _decodeFeed(http.Response response) {
  // Some feeds omit charset. Let UTF-8 XML retain punctuation and emoji before
  // falling back to the server's HTTP encoding for legacy feeds.
  try {
    return utf8.decode(response.bodyBytes);
  } on FormatException {
    return response.body;
  }
}

// Negative keywords that strongly suggest "negative emotion" (Tragedy, Violence, Crime)
/*
const Set<String> _negativeKeywords = {
  'murder', 'kill', 'killed', 'killing', 'death', 'dead', 'died', 'fatal',
  'crash', 'suicide', 'massacre', 'terror', 'terrorist', 'bomb', 'attack',
  'assault', 'rape', 'sexual', 'victim', 'tragedy', 'disaster', 'collapse',
  'hostage', 'execution', 'torture', 'genocide', 'slaughter', 'bloodbath',
  'scandal', 'jail', 'prison', 'arrested', 'fraud', 'corrupt', 'cancer',
  'shooting', 'stabbed', 'violent', 'war', 'battle', 'casualty',
};
*/

// Create a singleton-like analyzer with our custom negative words
// This runs in pure Dart with zero native dependencies!
/*
SentimentAnalyzer _createSentimentAnalyzer() {
  return SentimentAnalyzer(
    lexicon: WordSentimentLexicon(
      language: LexiconLanguage.english,
      customNegativeWords: _negativeKeywords,
    ),
  );
}
*/

// Top-level function for compute
List<FeedItem> _parseAndFilterFeed(Map<String, dynamic> args) {
  final xmlString = args['xml'] as String;
  final feedUrl = args['url'] as String;
  final category = args['category'] as String;
  final sourceIconUrl = args['iconUrl'] as String?;
  final baseUrl = args['baseUrl'] as Uri;

  final items = _parseFeedXml(
    xmlString,
    feedUrl,
    baseUrl,
    category,
    sourceIconUrl,
  );

  // Create ML sentiment analyzer with custom negative words
  // final mlAnalyzer = _createSentimentAnalyzer();

  // Filter out negative sentiment
  return items.where((item) {
    final text = "${item.title}. ${item.description}";

    try {
      // 1. Check strict keywords first (fast path) - using word boundaries
      // 1. Keyword search DISABLED per user request (relying on ML/AFINN context)
      /*
      for (final word in _negativeKeywords) {
        // Use regex word boundary \b to match whole words only
        // e.g., "war" won't match "software"
        final wordPattern = RegExp(r'\b' + word + r'\b', caseSensitive: false);
        if (wordPattern.hasMatch(lowerText)) {
          developer.log('👻 FILTERED (Keyword "$word"): "${item.title}" ${item.description}');
          return false;
        }
      }
      */

      // 2. ML disabled per user request
      /*
      // Use ml_sentiment_simple for ML-based analysis (pure Dart, no native deps)
      final mlResult = mlAnalyzer.analyze(text);
      
      // Filter if ML score is negative (score ranges from -1 to 1)
      if (mlResult.score < 0) {
        developer.log('🤖 ML FILTERED: "${item.title}" (Score: ${mlResult.score}, Label: ${mlResult.label})');
        return false;
      }
      */

      // 3. Use sentiment_dart (AFINN-165)
      final afinnResult = Sentiment.analysis(text, emoji: true);

      // Only filter if AFINN score is significantly negative
      if (afinnResult.score < -2) {
        developer.log(
          '📊 AFINN FILTERED: "${item.title}" (Score: ${afinnResult.score})',
        );
        return false;
      }

      return true; // Keep the article
    } catch (e) {
      // On error, keep the article
      return true;
    }
  }).toList();
}

List<FeedItem> _parseFeedXml(
  String xmlString,
  String feedUrl,
  Uri baseUrl,
  String category,
  String? sourceIconUrl,
) {
  final root = XmlDocument.parse(xmlString).rootElement;
  return switch (root.name.local) {
    'rss' || 'RDF'
        when root.findElements('channel', namespace: '*').firstOrNull != null =>
      _parseRss(root, category, feedUrl, baseUrl, sourceIconUrl),
    'feed' => _parseAtom(root, category, feedUrl, baseUrl, sourceIconUrl),
    _ => throw const FormatException('Response does not contain a feed.'),
  };
}

XmlElement? _child(XmlElement element, String name) =>
    element.findElements(name, namespace: element.namespaceUri).firstOrNull;

List<FeedItem> _parseRss(
  XmlElement root,
  String category,
  String sourceUrl,
  Uri baseUrl,
  String? sourceIconUrl,
) {
  final items = <FeedItem>[];
  final channel = root.findElements('channel', namespace: '*').firstOrNull!;
  final sourceTitle = _child(channel, 'title')?.innerText ?? 'Unknown Source';

  final itemsParent = root.name.local == 'RDF' ? root : channel;
  for (final node in itemsParent.findElements(
    'item',
    namespace: channel.namespaceUri,
  )) {
    final title = _child(node, 'title')?.innerText ?? 'No Title';
    final link = _articleUrl(baseUrl, _child(node, 'link')?.innerText);
    if (link == null) continue;
    final description = _child(node, 'description')?.innerText ?? '';
    final pubDateStr = _child(node, 'pubDate')?.innerText;

    DateTime? pubDate;
    if (pubDateStr != null) {
      pubDate = _parseDate(pubDateStr);
    }

    // Try to find image
    String? imageUrl;

    // 1. Check enclosure
    final enclosure = _child(node, 'enclosure');
    if (enclosure != null) {
      final type = enclosure.getAttribute('type');
      if (type != null && type.startsWith('image/')) {
        imageUrl = enclosure.getAttribute('url');
      }
    }

    // 2. Check media:content / media:thumbnail
    if (imageUrl == null) {
      final mediaContents = node.findAllElements('media:content');
      if (mediaContents.isNotEmpty) {
        // Find one with image medium or type or just verify url
        final img = mediaContents.firstWhere((e) {
          final type = e.getAttribute('type');
          final medium = e.getAttribute('medium');
          return (type != null && type.startsWith('image/')) ||
              medium == 'image';
        }, orElse: () => mediaContents.first);
        imageUrl = img.getAttribute('url');
      }
    }

    if (imageUrl == null) {
      final thumbnail = node.findAllElements('media:thumbnail').firstOrNull;
      if (thumbnail != null) {
        imageUrl = thumbnail.getAttribute('url');
      }
    }

    // 3. Try to extract from description if still null (basic img tag regex)
    if (imageUrl == null && description.isNotEmpty) {
      final imgRegExp = RegExp(r'<img[^>]+src="([^">]+)"');
      final match = imgRegExp.firstMatch(description);
      if (match != null) {
        imageUrl = match.group(1);
      }
    }

    items.add(
      FeedItem(
        title: _cleanText(title),
        link: link,
        description: _cleanText(description),
        publishedDate: pubDate,
        source: _cleanText(sourceTitle),
        sourceUrl: sourceUrl,
        category: category,

        imageUrl: _articleUrl(baseUrl, imageUrl),
        sourceIconUrl: sourceIconUrl,
      ),
    );
  }
  return items;
}

List<FeedItem> _parseAtom(
  XmlElement root,
  String category,
  String sourceUrl,
  Uri baseUrl,
  String? sourceIconUrl,
) {
  final items = <FeedItem>[];
  final feedTitle = _child(root, 'title')?.innerText ?? 'Unknown Source';

  for (final node in root.findElements('entry', namespace: root.namespaceUri)) {
    final title = _child(node, 'title')?.innerText ?? 'No Title';

    // Atom links are attributes usually
    final links = node.findElements('link', namespace: node.namespaceUri);
    final altLink = links.where((element) {
      final rel = element.getAttribute('rel');
      return rel == null || rel == 'alternate';
    }).firstOrNull;
    final link = _articleUrl(baseUrl, altLink?.getAttribute('href'));
    if (link == null) continue;

    final summary = _child(node, 'summary')?.innerText ?? '';
    final content = _child(node, 'content')?.innerText ?? '';
    final description = summary.isNotEmpty ? summary : content;

    final updatedStr = _child(node, 'updated')?.innerText;
    final publishedStr = _child(node, 'published')?.innerText;

    DateTime? pubDate;
    if (publishedStr != null) {
      pubDate = DateTime.tryParse(publishedStr);
    } else if (updatedStr != null) {
      pubDate = DateTime.tryParse(updatedStr);
    }

    // Atom Image extraction
    String? imageUrl;

    // 1. enclosure link
    final enclosureLink = links
        .where(
          (e) =>
              e.getAttribute('rel') == 'enclosure' &&
              (e.getAttribute('type')?.startsWith('image/') ?? false),
        )
        .firstOrNull;
    imageUrl = enclosureLink?.getAttribute('href');

    // 2. media:content
    if (imageUrl == null) {
      final mediaContents = node.findAllElements('media:content');
      if (mediaContents.isNotEmpty) {
        imageUrl = mediaContents.first.getAttribute('url');
      }
    }

    if (imageUrl == null) {
      final thumbnail = node.findAllElements('media:thumbnail').firstOrNull;
      if (thumbnail != null) {
        imageUrl = thumbnail.getAttribute('url');
      }
    }

    // 3. Description/Content regex
    if (imageUrl == null && description.isNotEmpty) {
      final imgRegExp = RegExp(r'<img[^>]+src="([^">]+)"');
      final match = imgRegExp.firstMatch(description);
      if (match != null) {
        imageUrl = match.group(1);
      }
    }

    items.add(
      FeedItem(
        title: _cleanText(title),
        link: link,
        description: _cleanText(description),
        publishedDate: pubDate,
        source: _cleanText(feedTitle),
        sourceUrl: sourceUrl,
        category: category,

        imageUrl: _articleUrl(baseUrl, imageUrl),
        sourceIconUrl: sourceIconUrl,
      ),
    );
  }
  return items;
}

String? _articleUrl(Uri base, String? value) {
  final reference = value?.trim();
  if (reference == null || reference.isEmpty) return null;
  final uri = Uri.tryParse(reference);
  if (uri == null) return null;
  final target = base.resolveUri(uri);
  if ((target.scheme != 'https' && target.scheme != 'http') ||
      target.host.isEmpty ||
      target.userInfo.isNotEmpty) {
    return null;
  }
  return target.toString();
}

DateTime? _parseDate(String dateStr) {
  // Try standard RFC822/1123
  try {
    return HttpDate.parse(dateStr);
  } catch (_) {}

  // Try parsing with Intl if needed, or simple DateFormat
  // Most RSS feeds use RFC822: "Mon, 25 Dec 2023 12:00:00 GMT"
  // Dart's HttpDate handles this.

  // Sometimes it's ISO8601
  try {
    return DateTime.parse(dateStr);
  } catch (_) {}

  return null;
}

String _cleanText(String text) {
  // Simple HTML tag removal if needed, or decoding entities
  // For now return as is or minimal cleanup
  return text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}
