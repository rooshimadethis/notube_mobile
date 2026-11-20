import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:notube_shared/alternative.pb.dart';

import '../screens/webview_screen.dart';

class AlternativeCard extends StatelessWidget {
  final Alternative alternative;
  final VoidCallback? onLongPress;

  const AlternativeCard({
    super.key,
    required this.alternative,
    this.onLongPress,
  });

  Future<void> _launchUrl(BuildContext context) async {
    if (alternative.bypassPaywall) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) =>
              WebViewScreen(url: alternative.url, title: alternative.title),
          fullscreenDialog: true,
        ),
      );
    } else {
      final Uri url = Uri.parse(alternative.url);
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not launch $url');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _launchUrl(context),
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIcon(alternative.category, colors),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alternative.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      alternative.description,
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(String category, ColorScheme colors) {
    IconData iconData;

    switch (category) {
      case 'custom':
        iconData = Icons.star;
        break;
      case 'photography':
        iconData = Icons.camera_alt;
        break;
      case 'books':
        iconData = Icons.book;
        break;
      case 'software':
      default:
        iconData = Icons.computer;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(iconData, color: colors.onSecondaryContainer, size: 24),
    );
  }
}
