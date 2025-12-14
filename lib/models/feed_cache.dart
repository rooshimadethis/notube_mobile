import 'package:notube_mobile/models/feed_item.dart';

class FeedCacheEntry {
  final List<FeedItem> items;
  final DateTime timestamp; // When we last successfully checked (200 or 304)
  final String? etag;
  final String? lastModified;

  FeedCacheEntry({
    required this.items, 
    required this.timestamp,
    this.etag,
    this.lastModified,
  });
}

enum FetchStatus { success, notModified, error }

class FetchResult {
  final FetchStatus status;
  final List<FeedItem> items;
  final String? etag;
  final String? lastModified;

  FetchResult.success({
    required this.items, 
    this.etag, 
    this.lastModified
  }) : status = FetchStatus.success;

  FetchResult.notModified() 
      : status = FetchStatus.notModified, items = [], etag = null, lastModified = null;

  FetchResult.error() 
      : status = FetchStatus.error, items = [], etag = null, lastModified = null;
}
