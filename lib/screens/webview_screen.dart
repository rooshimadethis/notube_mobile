import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class WebViewScreen extends StatefulWidget {
  final String url;
  final String title;

  const WebViewScreen({
    super.key,
    required this.url,
    required this.title,
  });

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;
  late final TextEditingController _urlController;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    final initialUri = Uri.parse(widget.url);
    final initialHost = initialUri.host;
    _urlController = TextEditingController(text: widget.url);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0F172A))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _urlController.text = url;
              });
            }
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() => _isLoading = false);
            }
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('Web resource error: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            return _handleNavigation(request.url, initialHost);
          },
        ),
      )
      ..loadRequest(initialUri);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  NavigationDecision _handleNavigation(String url, String initialHost) {
    // ... existing logic ...
    final uri = Uri.parse(url);
    final host = uri.host;

    // 1. Allow if already on archive sites
    if (host.contains('archive.ph') || 
        host.contains('archive.is') || 
        host.contains('archive.today') ||
        host.contains('archive.li') ||
        host.contains('archive.vn') ||
        host.contains('archive.fo') ||
        host.contains('archive.md')) {
      return NavigationDecision.navigate;
    }

    // 2. Allow external links (don't archive them)
    // We check if the host ends with the initial host to handle subdomains
    // e.g. initial: nytimes.com, current: www.nytimes.com -> match
    if (!host.endsWith(initialHost) && !initialHost.endsWith(host)) {
      return NavigationDecision.navigate;
    }

    // 3. Check if it's a "Home" page
    if (uri.path.isEmpty || uri.path == '/') {
      return NavigationDecision.navigate;
    }

    // 4. Check for common category/section patterns
    final lowerPath = uri.path.toLowerCase();
    if (lowerPath.contains('/category/') || 
        lowerPath.contains('/tag/') || 
        lowerPath.contains('/topic/') ||
        lowerPath.contains('/section/') ||
        lowerPath.contains('/author/')) {
      return NavigationDecision.navigate;
    }

    // 5. Assume it's an article -> Redirect to archive.ph
    // Remove query parameters to clean the URL
    final cleanUri = uri.replace(queryParameters: {});
    String cleanUrl = cleanUri.toString();
    if (cleanUrl.endsWith('?')) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
    }
    
    final archiveUrl = 'https://archive.ph/$cleanUrl';
    debugPrint('Redirecting to archive: $archiveUrl');
    
    // We must load the new request asynchronously to avoid blocking the delegate
    // and to ensure the current navigation is cancelled first.
    Future.microtask(() => _controller.loadRequest(Uri.parse(archiveUrl)));
    
    return NavigationDecision.prevent;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else {
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F172A),
          title: TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.1),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              hintText: 'Search or enter URL',
              hintStyle: TextStyle(color: Colors.grey[400]),
            ),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (value) {
              String url = value.trim();
              if (url.isEmpty) return;

              if (!url.startsWith('http://') && !url.startsWith('https://')) {
                if (url.contains('.') && !url.contains(' ')) {
                   url = 'https://$url';
                } else {
                   // Treat as search query
                   url = 'https://www.google.com/search?q=${Uri.encodeComponent(url)}';
                }
              }
              _controller.loadRequest(Uri.parse(url));
            },
          ),
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              color: const Color(0xFF1E293B),
              onSelected: (value) async {
                if (value == 'open_external') {
                  final currentUrl = await _controller.currentUrl();
                  if (currentUrl != null) {
                    final uri = Uri.parse(currentUrl);
                    try {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    } catch (e) {
                      debugPrint('Could not launch $uri: $e');
                    }
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'open_external',
                  child: Text(
                    'Open in external browser',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(
                  color: Colors.indigoAccent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
