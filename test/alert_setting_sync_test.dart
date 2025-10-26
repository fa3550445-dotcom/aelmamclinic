import 'package:flutter_test/flutter_test.dart';

import 'package:aelmamclinic/models/alert_setting.dart';

void main() {
  group('AlertSetting decimal threshold sync', () {
    test('local → remote → local keeps decimal precision', () {
      final now = DateTime.utc(2024, 1, 1);
      final alert = AlertSetting(
        id: 10,
        itemId: 5,
        threshold: 2.75,
        isEnabled: true,
        lastTriggered: now,
        createdAt: now,
      );

      final localMap = alert.toMap();
      expect(localMap['threshold'], equals(2.75));

      final remotePayload = {
        'id': alert.id,
        'item_id': alert.itemId,
        'threshold': localMap['threshold'],
        'is_enabled': localMap['is_enabled'],
        'last_triggered': localMap['last_triggered'],
        'created_at': localMap['created_at'],
        'notify_time': '2024-01-02T00:00:00.000Z',
      };

      final roundTrip = AlertSetting.fromMap(remotePayload);
      expect(roundTrip.threshold, equals(alert.threshold));

      final roundTripMap = roundTrip.toMap();
      expect(roundTripMap['threshold'], equals(alert.threshold));
    });

    test('remote string threshold parses to double', () {
      final alert = AlertSetting.fromMap({
        'id': 11,
        'item_id': 9,
        'threshold': '3.25',
        'is_enabled': 1,
        'created_at': '2024-01-01T00:00:00.000Z',
      });

      expect(alert.threshold, equals(3.25));
    });
  });
}
