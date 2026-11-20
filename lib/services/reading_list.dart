import '../models/feed_item.dart';

const readingListLength = 12;

List<FeedItem> buildReadingList(
  Iterable<FeedItem> articles, {
  required bool Function(String) isRead,
  required DateTime now,
}) {
  final seen = <String>{};
  final followed = articles.where((item) {
    return !isRead(item.link) &&
        !_opensYouTube(item.link) &&
        seen.add(item.link);
  }).toList();
  final result = <FeedItem>[];
  final byCategory = <String, int>{};
  final byPublisher = <String, int>{};
  final archiveCutoff = now.subtract(const Duration(days: 30));
  final archive = followed.where((item) {
    return item.publishedDate?.isBefore(archiveCutoff) ?? false;
  }).firstOrNull;

  void add(FeedItem item) {
    result.add(item);
    byCategory.update(_topic(item), (count) => count + 1, ifAbsent: () => 1);
    byPublisher.update(
      _publisher(item),
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    followed.remove(item);
  }

  while (result.length < readingListLength) {
    if (result.length == 9 &&
        archive != null &&
        followed.contains(archive) &&
        (byPublisher[_publisher(archive)] ?? 0) < 2) {
      add(archive);
      continue;
    }
    // Input is newest-first. Category rotation keeps recency as the tie-breaker.
    FeedItem? next;
    var lowestCount = readingListLength;
    for (final item in followed) {
      if ((byPublisher[_publisher(item)] ?? 0) >= 2) continue;
      final count = byCategory[_topic(item)] ?? 0;
      if (count >= lowestCount) continue;
      next = item;
      lowestCount = count;
      if (count == 0) break;
    }
    if (next == null) break;
    add(next);
  }
  return result;
}

String _publisher(FeedItem item) =>
    Uri.tryParse(item.sourceUrl)?.host.replaceFirst(RegExp(r'^www\.'), '') ??
    item.sourceUrl;

String _topic(FeedItem item) => switch (item.category) {
  'Engineering blogs' ||
  'Machine Learning' ||
  'Tech News' ||
  'Startup' ||
  'Products & Ideas' => 'Technology',
  'Learning' || 'Neuroscience' || 'Psychology' => 'Mind & learning',
  _ => item.category,
};

bool _opensYouTube(String link) {
  final host = Uri.tryParse(link)?.host.toLowerCase() ?? '';
  return host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
}
