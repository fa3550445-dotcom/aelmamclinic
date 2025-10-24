import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'fake-anon-key',
    );
  });

  tearDownAll(() async {
    await Supabase.instance.client.auth.signOut();
  });

  group('AuthProvider permissions gating', () {
    late AuthProvider provider;

    setUp(() {
      provider = AuthProvider(listenAuthChanges: false);
      provider.debugSetCurrentUser({'isSuperAdmin': false});
    });

    tearDown(() {
      provider.dispose();
    });

    test('featureAllowed defaults to false before permissions load', () {
      expect(provider.permissionsLoaded, isFalse);
      expect(provider.featureAllowed('any'), isFalse);
      expect(provider.canCreate, isFalse);
    });

    test('featureAllowed respects loaded permissions', () {
      provider.debugSetPermissions(
        allowed: {'chat'},
        canCreate: true,
        canUpdate: false,
        canDelete: false,
        loaded: true,
        error: null,
      );

      expect(provider.permissionsLoaded, isTrue);
      expect(provider.featureAllowed('chat'), isTrue);
      expect(provider.featureAllowed('reports'), isFalse);
      expect(provider.canCreate, isTrue);
      expect(provider.canUpdate, isFalse);
      expect(provider.canDelete, isFalse);
      expect(provider.permissionsError, isNull);
    });

    test('super admin bypasses permission gating even when not loaded', () {
      provider.debugSetCurrentUser({'isSuperAdmin': true});
      expect(provider.featureAllowed('anything'), isTrue);
      expect(provider.canDelete, isTrue);
    });
  });
}
