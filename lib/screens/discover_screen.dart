import 'package:flutter/material.dart';

import '../models/feed_item.dart';
import '../models/feed_source.dart';
import '../services/feed_service.dart';
import '../widgets/feed_article_card.dart';
import 'webview_screen.dart';

const _background = Color(0xFF0F172A);

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({
    super.key,
    required this.isActive,
    required this.sourceRevision,
    required this.onSourcesChanged,
  });

  final bool isActive;
  final int sourceRevision;
  final VoidCallback onSourcesChanged;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _service = FeedService();
  late Future<List<FeedSource>> _catalog;
  Future<List<FeedSource>>? _smallWeb;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _catalog = _loadCatalog();
    if (widget.isActive) _smallWeb = _service.loadSmallWebSources();
  }

  @override
  void didUpdateWidget(covariant DiscoverScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sourceRevision != oldWidget.sourceRevision) {
      _catalog = _loadCatalog();
    }
    if (widget.isActive &&
        (!oldWidget.isActive ||
            widget.sourceRevision != oldWidget.sourceRevision)) {
      _smallWeb = _service.loadSmallWebSources();
    }
  }

  Future<List<FeedSource>> _loadCatalog() async {
    final sources = await _service.loadFeedSources();
    final preferences = await _service.getFeedPreferences();
    final available = sources
        .where((source) => _service.isDiscoverableSource(source, preferences))
        .toList();
    return available..sort((first, second) {
      if (first.suggested != second.suggested) return first.suggested ? -1 : 1;
      return first.title.toLowerCase().compareTo(second.title.toLowerCase());
    });
  }

  void _preview(FeedSource source) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            _SourcePreview(source: source, onFollowed: widget.onSourcesChanged),
      ),
    );
  }

  Widget _publisherList({
    required List<FeedSource> catalog,
    required AsyncSnapshot<List<FeedSource>> smallWeb,
  }) {
    bool matches(FeedSource source) =>
        '${source.title} ${source.category}'.toLowerCase().contains(_query);

    final fromCatalog = catalog.where(matches).toList();
    final fromSmallWeb = (smallWeb.data ?? []).where(matches).toList();
    final waiting = smallWeb.connectionState == ConnectionState.waiting;

    if (_query.isNotEmpty && fromCatalog.isEmpty && fromSmallWeb.isEmpty) {
      return Center(
        child: waiting
            ? const CircularProgressIndicator()
            : const Text('No matching publishers.'),
      );
    }

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        if (_query.isEmpty || fromSmallWeb.isNotEmpty) ...[
          _sectionTitle('Kagi Small Web'),
          if (fromSmallWeb.isNotEmpty)
            _publisherCards(fromSmallWeb)
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: waiting
                    ? const LinearProgressIndicator()
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => setState(
                            () => _smallWeb = _service.loadSmallWebSources(),
                          ),
                          child: const Text(
                            'No new publishers available. Retry',
                          ),
                        ),
                      ),
              ),
            ),
        ],
        if (fromCatalog.isNotEmpty) ...[
          _sectionTitle('Browse catalog'),
          _publisherCards(fromCatalog),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _sectionTitle(String title) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFFAFC8F5),
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  Widget _publisherCards(List<FeedSource> sources) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    sliver: SliverList.builder(
      itemCount: sources.length,
      itemBuilder: (context, index) {
        final source = sources[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          color: const Color(0xFF1B263B),
          child: ListTile(
            title: Text(source.title),
            subtitle: Text(source.category),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _preview(source),
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: _background,
        appBar: AppBar(
          backgroundColor: _background,
          title: const Text('Discover'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                onChanged: (query) =>
                    setState(() => _query = query.trim().toLowerCase()),
                decoration: const InputDecoration(
                  hintText: 'Search publishers or topics',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<FeedSource>>(
                future: _catalog,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: TextButton(
                        onPressed: () =>
                            setState(() => _catalog = _loadCatalog()),
                        child: const Text('Couldn’t load publishers. Retry'),
                      ),
                    );
                  }
                  final sources = snapshot.data;
                  if (sources == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return FutureBuilder<List<FeedSource>>(
                    future: _smallWeb,
                    builder: (context, smallWeb) =>
                        _publisherList(catalog: sources, smallWeb: smallWeb),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourcePreview extends StatefulWidget {
  const _SourcePreview({required this.source, required this.onFollowed});

  final FeedSource source;
  final VoidCallback onFollowed;

  @override
  State<_SourcePreview> createState() => _SourcePreviewState();
}

class _SourcePreviewState extends State<_SourcePreview> {
  final _service = FeedService();
  late Future<List<FeedItem>> _articles;
  bool _saving = false;
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _articles = _loadArticles();
  }

  Future<List<FeedItem>> _loadArticles({bool refresh = false}) async {
    final articles = await _service.fetchFeeds([
      widget.source,
    ], forceRefresh: refresh);
    final seen = <String>{};
    return articles.where((article) => seen.add(article.link)).toList();
  }

  Future<void> _refresh() async {
    setState(() => _articles = _loadArticles(refresh: true));
    // FutureBuilder presents errors in the preview.
    try {
      await _articles;
    } catch (_) {}
  }

  Future<void> _follow() async {
    if (_saving || _following) return;
    setState(() => _saving = true);
    try {
      await _service.followSource(widget.source);
      if (!mounted) return;
      // Both tabs read the same saved preferences after this write completes.
      widget.onFollowed();
      setState(() => _following = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t follow this publisher. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _open(FeedItem item) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => WebViewScreen(url: item.link, title: item.title),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: Scaffold(
          backgroundColor: _background,
          appBar: AppBar(
            backgroundColor: _background,
            title: Text(widget.source.title),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.tonal(
                  onPressed: _following || _saving ? null : _follow,
                  child: Text(
                    _following
                        ? 'Following'
                        : _saving
                        ? 'Saving…'
                        : 'Follow',
                  ),
                ),
              ),
            ],
          ),
          body: FutureBuilder<List<FeedItem>>(
            future: _articles,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final articles = snapshot.data ?? [];
              if (articles.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No articles available right now.'),
                      TextButton(
                        onPressed: _refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  itemCount: articles.length,
                  itemBuilder: (context, index) {
                    final item = articles[index];
                    return FeedArticleCard(
                      item: item,
                      showSource: false,
                      onOpen: () => _open(item),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
