import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/alternative.dart';

class AlternativeCard extends StatelessWidget {
  final Alternative alternative;

  const AlternativeCard({super.key, required this.alternative});

  Future<void> _launchUrl() async {
    final Uri url = Uri.parse(alternative.url);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw Exception('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.white.withOpacity(0.1),
      child: InkWell(
        onTap: _launchUrl,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIcon(alternative.category),
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
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      alternative.description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[400],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(String category) {
    IconData iconData;
    Color color;

    switch (category) {
      case 'custom':
        iconData = Icons.star;
        color = Colors.yellow;
        break;
      case 'photography':
        iconData = Icons.camera_alt;
        color = Colors.indigoAccent;
        break;
      case 'books':
        iconData = Icons.book;
        color = Colors.indigoAccent;
        break;
      case 'software':
      default:
        iconData = Icons.computer;
        color = Colors.indigoAccent;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(iconData, color: color, size: 24),
    );
  }
}
