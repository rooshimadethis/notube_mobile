import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sentiment_dart/sentiment_dart.dart';
// import 'package:ml_sentiment_simple/ml_sentiment_simple.dart';
import 'package:xml/xml.dart';

import 'dart:developer' as developer;
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

// import 'sentiment_ai_service.dart'; // Disabled - native library issues
import '../models/feed_item.dart';

class FeedSource {
  final String title;
  final String url;
  final String category;
  final bool enabled;
  
  const FeedSource({
    required this.title, 
    required this.url,
    required this.category,
    this.enabled = true,
  });
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FeedSource &&
          runtimeType == other.runtimeType &&
          url == other.url;

  @override
  int get hashCode => url.hashCode;
}

class FeedService {
  final http.Client _client = http.Client();
  // final SentimentAiService _aiService = SentimentAiService(); // Disabled
  // bool _aiInitialized = false; // Disabled

  // Cache for feed URLs to avoid re-parsing OPML constantly if not needed
  // But for now we just load every time or rely on caller to manage state
  
  static const String _disabledFeedsKey = 'disabled_feed_urls';
  static const String _explicitlyEnabledFeedsKey = 'explicitly_enabled_feed_urls';

  // Cache for feed items: URL -> Cache Entry
  final Map<String, _FeedCacheEntry> _cache = {};

  // Smart TTL: Check for updates after 1 hour.
  // Since we use Conditional GETs (ETag), checks are cheap!
  static const Duration _cacheTtl = Duration(hours: 1);

  Future<List<FeedSource>> loadFeedSources() async {
    final List<FeedSource> sources = [];
    try {
      // Load feeds.opml
      final feedsOpml = await rootBundle.loadString('feeds.opml');
      sources.addAll(_parseOpml(feedsOpml));
    } catch (e) {
      developer.log("Error loading OPML assets: $e");
    }
    return sources; // Duplicates handled in parsing or assumed unique by URL
  }

  Future<Set<String>> getDisabledUrls() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_disabledFeedsKey)?.toSet() ?? {};
  }

  Future<void> setDisabledUrls(Set<String> disabledUrls) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_disabledFeedsKey, disabledUrls.toList());
  }

  Future<Set<String>> getExplicitlyEnabledUrls() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_explicitlyEnabledFeedsKey)?.toSet() ?? {};
  }

  Future<void> setExplicitlyEnabledUrls(Set<String> enabledUrls) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_explicitlyEnabledFeedsKey, enabledUrls.toList());
  }

  // Helper to get only enabled URLs
  Future<List<FeedSource>> getEnabledFeedSources() async {
    final allSources = await loadFeedSources();
    final disabled = await getDisabledUrls();
    final enabledOverrides = await getExplicitlyEnabledUrls();
    
    return allSources
        .where((s) => (s.enabled || enabledOverrides.contains(s.url)) && !disabled.contains(s.url))
        .toList();
  }

  List<FeedSource> _parseOpml(String opmlContent) {
    final List<FeedSource> sources = [];
    try {
      final document = XmlDocument.parse(opmlContent);
      final outlines = document.findAllElements('outline');
      
      for (var node in outlines) {
        final type = node.getAttribute('type');
        final xmlUrl = node.getAttribute('xmlUrl');
        final title = node.getAttribute('title') ?? node.getAttribute('text') ?? 'Unknown Config';
        final category = node.getAttribute('category') ?? 'Uncategorized';
        final enabledStr = node.getAttribute('enabled');
        final isEnabled = enabledStr?.toLowerCase() != 'false'; // Default to true if missing or not false
        
        if (type == 'rss' && xmlUrl != null && xmlUrl.isNotEmpty) {
          sources.add(FeedSource(
            title: title, 
            url: xmlUrl, 
            category: category,
            enabled: isEnabled,
          ));
        }
      }
    } catch (e) {
      developer.log("Error parsing OPML: $e");
    }
    return sources;
  }

  Future<List<FeedItem>> fetchFeeds(List<FeedSource> sources, {bool forceRefresh = false}) async {
    // 1. Remove deselected feeds from cache
    final sourceUrls = sources.map((s) => s.url).toSet();
    _cache.removeWhere((url, _) => !sourceUrls.contains(url));

    // 2. Identify which sources need fetching
    final List<Future<void>> fetchFutures = [];

    for (var source in sources) {
      final cachedEntry = _cache[source.url];
      
      // Check if cache is valid (exists AND not expired)
      bool isCacheValid = false;
      if (cachedEntry != null) {
        final age = DateTime.now().difference(cachedEntry.timestamp);
        if (age < _cacheTtl) {
          isCacheValid = true;
        } else {
          developer.log("Cache expired for ${source.title} (Age: ${age.inHours}h)");
        }
      }

      // Fetch if forced refresh OR cache invalid (missing or expired)
      if (forceRefresh || !isCacheValid) {
        fetchFutures.add(_fetchAndUpdateCache(source));
      }
    }

    // 3. Wait for all fetches to complete
    if (fetchFutures.isNotEmpty) {
      await Future.wait(fetchFutures);
    }
    
    // 4. Aggregate all items from cache
    final allItems = <FeedItem>[];
    for (var source in sources) {
      if (_cache.containsKey(source.url)) {
        allItems.addAll(_cache[source.url]!.items);
      }
    }

    // 5. Sort
    allItems.sort((a, b) {
      if (a.publishedDate == null && b.publishedDate == null) return 0;
      if (a.publishedDate == null) return 1;
      if (b.publishedDate == null) return -1;
      return b.publishedDate!.compareTo(a.publishedDate!); // Newest first
    });
    
    return allItems;
  }

  Future<void> _fetchAndUpdateCache(FeedSource source) async {
    final cached = _cache[source.url];
    
    // Perform Conditional GET
    final result = await _fetchFeed(
      source, 
      etag: cached?.etag, 
      lastModified: cached?.lastModified,
    );

    if (result.status == _FetchStatus.notModified) {
      // 304: Server says our cache is still good. Just update timestamp.
      developer.log("✅ 304 Not Modified: ${source.title}");
      if (cached != null) {
        _cache[source.url] = _FeedCacheEntry(
          items: cached.items, // Keep old items
          timestamp: DateTime.now(),
          etag: cached.etag, // Keep old headers
          lastModified: cached.lastModified,
        );
      }
    } else if (result.status == _FetchStatus.success) {
      // 200: New content!
      developer.log("⬇️ Fetched New Content: ${source.title} (${result.items.length} items)");
      if (result.items.isNotEmpty) {
        _cache[source.url] = _FeedCacheEntry(
          items: result.items,
          timestamp: DateTime.now(),
          etag: result.etag,
          lastModified: result.lastModified,
        );
      }
    }
  }

  Future<_FetchResult> _fetchFeed(FeedSource source, {String? etag, String? lastModified}) async {
    try {
      final headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Upgrade-Insecure-Requests': '1',
      };

      if (etag != null) headers['If-None-Match'] = etag;
      if (lastModified != null) headers['If-Modified-Since'] = lastModified;

      final response = await _client.get(
        Uri.parse(source.url),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 304) {
        return _FetchResult.notModified();
      } else if (response.statusCode == 200) {
        final items = await compute(_parseAndFilterFeed, {
          'xml': response.body, 
          'url': source.url,
          'category': source.category,
        });

        return _FetchResult.success(
          items: items, 
          etag: response.headers['etag'], 
          lastModified: response.headers['last-modified'],
        );
      } else {
        developer.log("Failed to fetch feed ${source.url}: ${response.statusCode}");
      }
    } catch (e) {
      developer.log("Error fetching feed ${source.url}: $e");
    }
    return _FetchResult.error();
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
  
  final items = _parseFeedXml(xmlString, feedUrl, category);
  
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
        developer.log('📊 AFINN FILTERED: "${item.title}" (Score: ${afinnResult.score})');
        return false;
      }
      
      return true; // Keep the article
    } catch (e) {
      // On error, keep the article
      return true;
    }
  }).toList();
}

List<FeedItem> _parseFeedXml(String xmlString, String feedUrl, String category) {
  try {
    final document = XmlDocument.parse(xmlString);
    
    // Check for RSS
    final rss = document.findAllElements('rss').firstOrNull;
    if (rss != null) {
      return _parseRss(document, category);
    }
    
    // Check for Atom
    final feed = document.findAllElements('feed').firstOrNull;
    if (feed != null) {
      return _parseAtom(document, category);
    }

    // RDF/RSS 1.0
    final rdf = document.findAllElements('rdf:RDF').firstOrNull;
    if (rdf != null) {
       return _parseRss(document, category); // Structure is similar enough mostly
    }
    
  } catch (e) {
    developer.log("Error parsing XML for $feedUrl: $e");
  }
  return [];
}

List<FeedItem> _parseRss(XmlDocument document, String category) {
  final items = <FeedItem>[];
  final channel = document.findAllElements('channel').firstOrNull;
  final sourceTitle = channel?.findElements('title').firstOrNull?.innerText ?? 'Unknown Source';

  for (var node in document.findAllElements('item')) {
    final title = node.findElements('title').firstOrNull?.innerText ?? 'No Title';
    final link = node.findElements('link').firstOrNull?.innerText ?? '';
    final description = node.findElements('description').firstOrNull?.innerText ?? '';
    final pubDateStr = node.findElements('pubDate').firstOrNull?.innerText;
    
    DateTime? pubDate;
    if (pubDateStr != null) {
      pubDate = _parseDate(pubDateStr);
    }

    // Try to find image
    String? imageUrl;
    
    // 1. Check enclosure
    final enclosure = node.findElements('enclosure').firstOrNull;
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
           return (type != null && type.startsWith('image/')) || medium == 'image';
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

    items.add(FeedItem(
      title: _cleanText(title),
      link: link,
      description: _cleanText(description),
      publishedDate: pubDate,
      source: _cleanText(sourceTitle),
      category: category,
      imageUrl: imageUrl,
    ));
  }
  return items;
}

List<FeedItem> _parseAtom(XmlDocument document, String category) {
  final items = <FeedItem>[];
  final feedTitle = document.findAllElements('title').firstOrNull?.innerText ?? 'Unknown Source';

  for (var node in document.findAllElements('entry')) {
    final title = node.findElements('title').firstOrNull?.innerText ?? 'No Title';
    
    // Atom links are attributes usually
    String link = '';
    final links = node.findElements('link');
    final altLink = links.firstWhere(
      (e) => e.getAttribute('rel') == 'alternate' || e.getAttribute('rel') == null,
      orElse: () => links.first,
    );
    link = altLink.getAttribute('href') ?? '';

    final summary = node.findElements('summary').firstOrNull?.innerText ?? '';
    final content = node.findElements('content').firstOrNull?.innerText ?? '';
    final description = summary.isNotEmpty ? summary : content;
    
    final updatedStr = node.findElements('updated').firstOrNull?.innerText;
    final publishedStr = node.findElements('published').firstOrNull?.innerText;
    
    DateTime? pubDate;
    if (publishedStr != null) {
      pubDate = DateTime.tryParse(publishedStr);
    } else if (updatedStr != null) {
      pubDate = DateTime.tryParse(updatedStr);
    }

    // Atom Image extraction
    String? imageUrl;
    
    // 1. enclosure link
    final enclosureLink = links.firstWhere(
      (e) => e.getAttribute('rel') == 'enclosure' && (e.getAttribute('type')?.startsWith('image/') ?? false),
      orElse: () => XmlElement(XmlName('dummy')),
    );
    if (enclosureLink.name.local != 'dummy') {
      imageUrl = enclosureLink.getAttribute('href');
    }

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

    items.add(FeedItem(
      title: _cleanText(title),
      link: link,
      description: _cleanText(description),
      publishedDate: pubDate,
      source: _cleanText(feedTitle),
      category: category,
      imageUrl: imageUrl,
    ));
  }
  return items;
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

class _FeedCacheEntry {
  final List<FeedItem> items;
  final DateTime timestamp; // When we last successfully checked (200 or 304)
  final String? etag;
  final String? lastModified;

  _FeedCacheEntry({
    required this.items, 
    required this.timestamp,
    this.etag,
    this.lastModified,
  });
}

enum _FetchStatus { success, notModified, error }

class _FetchResult {
  final _FetchStatus status;
  final List<FeedItem> items;
  final String? etag;
  final String? lastModified;

  _FetchResult.success({
    required this.items, 
    this.etag, 
    this.lastModified
  }) : status = _FetchStatus.success;

  _FetchResult.notModified() 
      : status = _FetchStatus.notModified, items = [], etag = null, lastModified = null;

  _FetchResult.error() 
      : status = _FetchStatus.error, items = [], etag = null, lastModified = null;
}
