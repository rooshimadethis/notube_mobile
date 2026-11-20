import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notube_mobile/screens/feed_source_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('can find and follow a suggested source by name', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Serve the catalog inside the test clock so the loading animation can settle.
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      if (const StringCodec().decodeMessage(message) != 'feeds.opml') {
        return null;
      }
      return ByteData.sublistView(
        utf8.encode('''
        <opml><body><outline title="Signal Blog" enabled="false" suggested="true"
          type="rss" xmlUrl="https://example.com/feed" category="Technology"/>
        </body></opml>
      '''),
      );
    });
    addTearDown(() {
      messenger.setMockMessageHandler('flutter/assets', null);
      rootBundle.evict('feeds.opml');
    });
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(home: FeedSourceScreen(onChanged: () => changes++)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Signal Blog');
    await tester.pumpAndSettle();
    expect(find.text('Suggested for discovery'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.widgetWithText(SwitchListTile, 'Signal Blog'));
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(changes, 1);
  });
}
