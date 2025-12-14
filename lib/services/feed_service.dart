import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:sentiment_dart/sentiment_dart.dart';
import 'package:xml/xml.dart';

import 'dart:developer' as developer;
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/feed_item.dart';

class FeedSource {
  final String title;
  final String url;
  final bool enabled;
  
  const FeedSource({
    required this.title, 
    required this.url,
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

  // Cache for feed URLs to avoid re-parsing OPML constantly if not needed
  // But for now we just load every time or rely on caller to manage state
  
  static const String _disabledFeedsKey = 'disabled_feed_urls';

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

  // Helper to get only enabled URLs
  Future<List<String>> getEnabledFeedUrls() async {
    final allSources = await loadFeedSources();
    final disabled = await getDisabledUrls();
    return allSources
        .where((s) => s.enabled && !disabled.contains(s.url))
        .map((s) => s.url)
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
        final enabledStr = node.getAttribute('enabled');
        final isEnabled = enabledStr?.toLowerCase() != 'false'; // Default to true if missing or not false
        
        if (type == 'rss' && xmlUrl != null && xmlUrl.isNotEmpty) {
          sources.add(FeedSource(title: title, url: xmlUrl, enabled: isEnabled));
        }
      }
    } catch (e) {
      developer.log("Error parsing OPML: $e");
    }
    return sources;
  }

  Future<List<FeedItem>> fetchFeeds(List<String> urls) async {
    // Limit concurrency or just fire all? For now fire all.
    // In production might want to limit to batch of 10-20.
    final futures = urls.map((url) => _fetchFeed(url));
    final results = await Future.wait(futures);
    
    // Flatten
    var allItems = results.expand((i) => i).toList();

    // Filter out negative sentiment
    allItems = allItems.where((item) {
      final text = "${item.title}. ${item.description}";
      // Simple cleaning of common HTML entities or just rely on raw text if clean enough
      // cleanup is already done in parsing.
      
      try {
        final result = Sentiment.analysis(text, emoji: true);
        return result.score >= 0; // Keep non-negative
      } catch (e) {
        // If analysis fails, keep it
        return true;
      }
    }).toList();

    allItems.sort((a, b) {
      if (a.publishedDate == null && b.publishedDate == null) return 0;
      if (a.publishedDate == null) return 1;
      if (b.publishedDate == null) return -1;
      return b.publishedDate!.compareTo(a.publishedDate!); // Newest first
    });
    
    return allItems;
  }

  Future<List<FeedItem>> _fetchFeed(String url) async {
    try {
      final response = await _client.get(
        Uri.parse(url),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          'Upgrade-Insecure-Requests': '1',
        },
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        return _parseFeedXml(response.body, url);
      } else {
        developer.log("Failed to fetch feed $url: ${response.statusCode}");
      }
    } catch (e) {
      developer.log("Error fetching feed $url: $e");
    }
    return [];
  }

  List<FeedItem> _parseFeedXml(String xmlString, String feedUrl) {
    try {
      final document = XmlDocument.parse(xmlString);
      
      // Check for RSS
      final rss = document.findAllElements('rss').firstOrNull;
      if (rss != null) {
        return _parseRss(document);
      }
      
      // Check for Atom
      final feed = document.findAllElements('feed').firstOrNull;
      if (feed != null) {
        return _parseAtom(document);
      }

      // RDF/RSS 1.0
      final rdf = document.findAllElements('rdf:RDF').firstOrNull;
      if (rdf != null) {
         return _parseRss(document); // Structure is similar enough mostly
      }
      
    } catch (e) {
      developer.log("Error parsing XML for $feedUrl: $e");
    }
    return [];
  }

  List<FeedItem> _parseRss(XmlDocument document) {
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
        imageUrl: imageUrl,
      ));
    }
    return items;
  }

  List<FeedItem> _parseAtom(XmlDocument document) {
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
}
