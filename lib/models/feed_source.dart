class FeedSource {
  final String title;
  final String url;
  final String category;
  final bool enabled;
  final String? iconUrl;
  
  const FeedSource({
    required this.title, 
    required this.url,
    required this.category,
    this.enabled = true,
    this.iconUrl,
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
