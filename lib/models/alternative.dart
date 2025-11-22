class Alternative {
  final String title;
  final String url;
  final String description;
  final String category;

  Alternative({
    required this.title,
    required this.url,
    required this.description,
    required this.category,
  });

  factory Alternative.fromJson(Map<String, dynamic> json) {
    return Alternative(
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      description: json['description'] ?? '',
      category: json['category'] ?? 'custom',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
      'description': description,
      'category': category,
    };
  }
}
