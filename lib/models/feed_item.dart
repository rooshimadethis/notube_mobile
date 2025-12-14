class FeedItem {
  final String title;
  final String link;
  final String description;
  final String? publishedDateStr; // Keep original string just in case
  final DateTime? publishedDate;
  final String source;
  final String sourceUrl;
  final String? imageUrl;

  final String category;

  FeedItem({
    required this.title,
    required this.link,
    required this.description,
    this.publishedDate,
    this.publishedDateStr,
    required this.source,
    required this.sourceUrl,
    required this.category,
    this.imageUrl,
  });

  @override
  String toString() {
    return 'FeedItem(title: $title, source: $source, date: $publishedDate, hasImage: ${imageUrl != null})';
  }
}
