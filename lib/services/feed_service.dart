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



class FeedService {
  static final FeedService _instance = FeedService._internal();
  factory FeedService() => _instance;
  FeedService._internal();

  final http.Client _client = http.Client();
  // final SentimentAiService _aiService = SentimentAiService(); // Disabled
  // bool _aiInitialized = false; // Disabled

  // Cache for feed URLs to avoid re-parsing OPML constantly if not needed
  // But for now we just load every time or rely on caller to manage state
  
  static const String _feedPreferencesKey = 'feed_preferences';
  static const String _readArticlesKey = 'read_articles';
  
  // Limit strictly to keep 'markArticleAsRead' fast (disk write on every tap).
  // 2000 is safe because RSS feeds usually rotate content (drop old items)
  // much faster than a user reads 2000 items.
  static const int _maxReadHistory = 2000;

  // Cache for feed items: URL -> Cache Entry
  final Map<String, FeedCacheEntry> _cache = {};

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
    // LinkedHashSet (Dart's default Set) preserves insertion order.
    // So the first items are the oldest.
    if (_readArticleUrls.length > _maxReadHistory) {
      // Create a list to remove the first item safely
      final first = _readArticleUrls.first;
      _readArticleUrls.remove(first);
    }

    // Save to disk
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_readArticlesKey, _readArticleUrls.toList());
  }

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
    await prefs.setString(_feedPreferencesKey, jsonEncode(preferences));
  }

  Future<void> updateFeedEnabledState(String url, bool isEnabled) async {
    final prefs = await getFeedPreferences();
    prefs[url] = isEnabled;
    await _savePreferences(prefs);
  }

  Future<void> disableFeedSource(String url) async {
    await updateFeedEnabledState(url, false);
  }

  bool isFeedEnabled(FeedSource source, Map<String, bool> preferences) {
    // If user has an explicit preference, use it. Otherwise use default.
    return preferences[source.url] ?? source.enabled;
  }

  // Helper to get only enabled URLs
  Future<List<FeedSource>> getEnabledFeedSources() async {
    final allSources = await loadFeedSources();
    final prefs = await getFeedPreferences();
    
    return allSources
        .where((s) => isFeedEnabled(s, prefs))
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

  bool isArticleRead(String url) {
    if (!_readArticlesLoaded) return false;
    return _readArticleUrls.contains(url);
  }

  Stream<List<FeedItem>> fetchFeedsStream(List<FeedSource> sources, {bool forceRefresh = false}) {
    final controller = StreamController<List<FeedItem>>();
    // Start fetching without awaiting, so we return the stream immediately
    _startStreamFetching(sources, forceRefresh, controller);
    return controller.stream;
  }

  Future<void> _startStreamFetching(
      List<FeedSource> sources, bool forceRefresh, StreamController<List<FeedItem>> controller) async {
    try {
      // Ensure read articles are loaded locally
      if (!_readArticlesLoaded) await loadReadArticles();

      // 1. Remove deselected feeds from cache
      final sourceUrls = sources.map((s) => s.url).toSet();
      _cache.removeWhere((url, _) => !sourceUrls.contains(url));

      // 2. Prepare initial state from cache
      final currentItems = <FeedItem>[];
      final List<FeedSource> sourcesToFetch = [];

      for (var source in sources) {
        final cachedEntry = _cache[source.url];

        bool isCacheValid = false;
        if (cachedEntry != null) {
          final age = DateTime.now().difference(cachedEntry.timestamp);
          if (age < _cacheTtl) {
            isCacheValid = true;
            currentItems.addAll(cachedEntry.items);
          } else {
            developer.log("Cache expired for ${source.title} (Age: ${age.inHours}h)");
          }
        }

        if (forceRefresh || !isCacheValid) {
          sourcesToFetch.add(source);
        } else if (cachedEntry != null) {
          // Keep existing items if valid
        }
      }

      // Initial yield: Show what we have in cache immediately
      // Sort first
      _sortItems(currentItems);
      if (!controller.isClosed) controller.add(List<FeedItem>.from(currentItems));

      if (sourcesToFetch.isEmpty) {
        await controller.close();
        return;
      }

      // 3. Parallel Fetching
      // We process each source in parallel. When one finishes, we update the stream.
      // We must guard against controller being closed if widget is disposed.

      await Future.wait(sourcesToFetch.map((source) async {
        try {
          await _fetchAndUpdateCache(source);
          
          if (controller.isClosed) return;

          // Re-aggregate everything safely
          // This is slightly inefficient (O(N*M)) but N (sources) and M (Total items) are small enough (<2000 items)
          final newItems = <FeedItem>[];
          for (var s in sources) {
            if (_cache.containsKey(s.url)) {
              newItems.addAll(_cache[s.url]!.items);
            }
          }
          _sortItems(newItems);
          
          if (!controller.isClosed) {
            controller.add(newItems);
          }
        } catch (e) {
            // Individual feed failure shouldn't kill the whole stream
            developer.log("Error in stream fetch for ${source.url}: $e");
        }
      }));

      if (!controller.isClosed) await controller.close();
    } catch (e) {
      if (!controller.isClosed) controller.addError(e);
      if (!controller.isClosed) await controller.close();
    }
  }
    

  
  void _sortItems(List<FeedItem> items) {
    items.sort((a, b) {
      if (a.publishedDate == null && b.publishedDate == null) return 0;
      if (a.publishedDate == null) return 1;
      if (b.publishedDate == null) return -1;
      return b.publishedDate!.compareTo(a.publishedDate!); 
    });
  }

  // Keeping original for backward compatibility or easy migration, but implementing it using the stream or leaving as is?
  // I will LEAVE existing fetchFeeds as is for safety (or reimplement it to wait for stream last element) 
  // and ADD the new one.
  
  Future<List<FeedItem>> fetchFeeds(List<FeedSource> sources, {bool forceRefresh = false}) async {
    // Just wait for the last emission of the stream
    return await fetchFeedsStream(sources, forceRefresh: forceRefresh).last;
  }



  Future<void> _fetchAndUpdateCache(FeedSource source) async {
    final cached = _cache[source.url];
    
    // Perform Conditional GET
    final result = await _fetchFeed(
      source, 
      etag: cached?.etag, 
      lastModified: cached?.lastModified,
    );

    if (result.status == FetchStatus.notModified) {
      // 304: Server says our cache is still good. Just update timestamp.
      developer.log("✅ 304 Not Modified: ${source.title}");
      if (cached != null) {
        _cache[source.url] = FeedCacheEntry(
          items: cached.items, // Keep old items
          timestamp: DateTime.now(),
          etag: cached.etag, // Keep old headers
          lastModified: cached.lastModified,
        );
      }
    } else if (result.status == FetchStatus.success) {
      // 200: New content!
      developer.log("⬇️ Fetched New Content: ${source.title} (${result.items.length} items)");
      if (result.items.isNotEmpty) {
        _cache[source.url] = FeedCacheEntry(
          items: result.items,
          timestamp: DateTime.now(),
          etag: result.etag,
          lastModified: result.lastModified,
        );
      }
    }
  }

  Future<FetchResult> _fetchFeed(FeedSource source, {String? etag, String? lastModified}) async {
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
        return FetchResult.notModified();
      } else if (response.statusCode == 200) {
        final items = await compute(_parseAndFilterFeed, {
          'xml': response.body, 
          'url': source.url,
          'category': source.category,
        });

        return FetchResult.success(
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
    return FetchResult.error();
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
      return _parseRss(document, category, feedUrl);
    }
    
    // Check for Atom
    final feed = document.findAllElements('feed').firstOrNull;
    if (feed != null) {
      return _parseAtom(document, category, feedUrl);
    }

    // RDF/RSS 1.0
    final rdf = document.findAllElements('rdf:RDF').firstOrNull;
    if (rdf != null) {
       return _parseRss(document, category, feedUrl); // Structure is similar enough mostly
    }
    
  } catch (e) {
    developer.log("Error parsing XML for $feedUrl: $e");
  }
  return [];
}

List<FeedItem> _parseRss(XmlDocument document, String category, String sourceUrl) {
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
      sourceUrl: sourceUrl,
      category: category,
      imageUrl: imageUrl,
    ));
  }
  return items;
}

List<FeedItem> _parseAtom(XmlDocument document, String category, String sourceUrl) {
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
      sourceUrl: sourceUrl,
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




