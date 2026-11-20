import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notube_mobile/screens/home_screen.dart';
import 'package:notube_mobile/services/auth_service.dart';
import 'package:notube_mobile/services/firestore_service.dart';
import 'package:notube_shared/alternative.pb.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestUser extends Fake implements User {
  TestUser(this.uid);

  @override
  final String uid;
}

class TestAuth extends Fake implements AuthService {
  final changes = StreamController<User?>();
  User? _currentUser;

  @override
  User? get currentUser => _currentUser;

  @override
  Stream<User?> get user => changes.stream;

  void switchAccount(String? uid) {
    _currentUser = uid == null ? null : TestUser(uid);
    changes.add(_currentUser);
  }
}

class TestFirestore extends Fake implements FirestoreService {
  final requests = <String, Completer<List<Alternative>?>>{};
  int initializations = 0;

  @override
  Future<List<Alternative>?> getUserAlternatives(String userId) =>
      requests.putIfAbsent(userId, Completer.new).future;

  @override
  Future<List<Alternative>> initializeUserAlternatives(
    String userId,
    List<Alternative> local,
  ) async {
    initializations++;
    return local;
  }
}

Alternative site(String title) => Alternative()
  ..title = title
  ..url = 'https://example.com/${title.toLowerCase()}';

void main() {
  late TestAuth auth;
  late TestFirestore cloud;

  setUp(() {
    auth = TestAuth();
    cloud = TestFirestore();
    final sharing = ReceiveSharingIntent.instance;
    ReceiveSharingIntent.setMockValues(
      initialMedia: [],
      mediaStream: const Stream.empty(),
    );
    addTearDown(() {
      ReceiveSharingIntent.instance = sharing;
    });
  });

  Future<SharedPreferences> openSavedSites(
    WidgetTester tester, {
    required String? userId,
    required String? lastSynced,
    required List<Alternative> local,
  }) async {
    SharedPreferences.setMockInitialValues({
      'showGratitudeJournal': false,
      'localItems': jsonEncode(
        local.map((item) => item.toProto3Json()).toList(),
      ),
      if (lastSynced != null) 'lastSyncedUserId': lastSynced,
    });
    final prefs = await SharedPreferences.getInstance();
    auth.switchAccount(userId);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AuthService>.value(value: auth),
          Provider<FirestoreService>.value(value: cloud),
          Provider<User?>.value(value: null),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    return prefs;
  }

  testWidgets('a stored empty list survives loading while signed out', (
    tester,
  ) async {
    await openSavedSites(tester, userId: null, lastSynced: null, local: []);
    await tester.pumpAndSettle();
    expect(find.text('No alternatives found.'), findsOneWidget);
  });

  testWidgets('an empty cloud list does not restore deleted sites', (
    tester,
  ) async {
    final prefs = await openSavedSites(
      tester,
      userId: 'same',
      lastSynced: 'same',
      local: [site('Old')],
    );
    cloud.requests['same']!.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No alternatives found.'), findsOneWidget);
    expect(prefs.getString('localItems'), '[]');
    expect(cloud.initializations, 0);
  });

  testWidgets('a missing cloud list initializes from the local copy', (
    tester,
  ) async {
    await openSavedSites(
      tester,
      userId: 'new',
      lastSynced: null,
      local: [site('Local')],
    );
    cloud.requests['new']!.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Local'), findsOneWidget);
    expect(cloud.initializations, 1);
  });

  testWidgets('choosing cloud data commits the local copy and sync marker', (
    tester,
  ) async {
    final prefs = await openSavedSites(
      tester,
      userId: 'current',
      lastSynced: null,
      local: [site('Local')],
    );
    cloud.requests['current']!.complete([site('Cloud')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Use cloud data'));
    await tester.pumpAndSettle();
    expect(find.text('Cloud'), findsOneWidget);
    expect(prefs.getString('localItems'), contains('Cloud'));
    expect(prefs.getString('lastSyncedUserId'), 'current');
  });

  testWidgets('a late response cannot overwrite another account’s sites', (
    tester,
  ) async {
    final prefs = await openSavedSites(
      tester,
      userId: 'previous',
      lastSynced: 'current',
      local: [site('Local')],
    );
    auth.switchAccount('current');
    await tester.pump();
    cloud.requests['current']!.complete([site('Current')]);
    await tester.pumpAndSettle();
    cloud.requests['previous']!.complete([site('Previous')]);
    await tester.pumpAndSettle();
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Previous'), findsNothing);
    expect(find.text('Sync Conflict'), findsNothing);
    expect(prefs.getString('localItems'), contains('Current'));
    expect(prefs.getString('lastSyncedUserId'), 'current');
  });
}
