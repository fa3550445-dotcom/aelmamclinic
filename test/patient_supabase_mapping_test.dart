import 'package:flutter_test/flutter_test.dart';

import 'package:aelmamclinic/models/patient.dart';

void main() {
  group('Patient Supabase mapping', () {
    test('insert scenario keeps doctor review flags', () {
      final now = DateTime.parse('2024-10-01T12:00:00.000Z');
      final patient = Patient(
        id: 1,
        name: 'Test Patient',
        age: 30,
        diagnosis: 'Routine check',
        paidAmount: 100,
        remaining: 50,
        registerDate: now,
        phoneNumber: '+9647000000000',
        healthStatus: 'stable',
        preferences: 'none',
        doctorId: 5,
        doctorName: 'Dr. Ali',
        doctorSpecialization: 'Cardiology',
        notes: 'needs follow-up',
        serviceType: 'clinic',
        serviceId: 7,
        serviceName: 'Consultation',
        serviceCost: 150,
        doctorShare: 30,
        doctorInput: 10,
        towerShare: 5,
        departmentShare: 5,
        doctorReviewPending: true,
        doctorReviewedAt: now,
        accountId: 'acc-1',
        deviceId: 'device-1',
        localId: 33,
        updatedAt: now,
      );

      final supabasePayload = patient.toSupabase();

      expect(supabasePayload['doctor_review_pending'], isTrue);
      expect(
        supabasePayload['doctor_reviewed_at'],
        equals(now.toIso8601String()),
      );

      final insertedRow = {
        ...supabasePayload,
        'id': 999,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      final restored = Patient.fromSupabase(insertedRow);

      expect(restored.doctorReviewPending, isTrue);
      expect(restored.doctorReviewedAt, equals(now));
      expect(restored.accountId, equals('acc-1'));
      expect(restored.deviceId, equals('device-1'));
      expect(restored.localId, equals(33));
    });

    test('update scenario toggles doctor review state', () {
      final insertedAt = DateTime.parse('2024-10-01T12:00:00.000Z');
      final reviewedAt = insertedAt.add(const Duration(hours: 2));

      final existingRow = {
        'id': 999,
        'account_id': 'acc-1',
        'device_id': 'device-1',
        'local_id': 33,
        'name': 'Test Patient',
        'age': 30,
        'diagnosis': 'Routine check',
        'paid_amount': 100,
        'remaining': 50,
        'register_date': insertedAt.toIso8601String(),
        'phone_number': '+9647000000000',
        'health_status': 'stable',
        'preferences': 'none',
        'doctor_id': 5,
        'doctor_name': 'Dr. Ali',
        'doctor_specialization': 'Cardiology',
        'notes': 'needs follow-up',
        'service_type': 'clinic',
        'service_id': 7,
        'service_name': 'Consultation',
        'service_cost': 150,
        'doctor_share': 30,
        'doctor_input': 10,
        'tower_share': 5,
        'department_share': 5,
        'doctor_review_pending': true,
        'doctor_reviewed_at': insertedAt.toIso8601String(),
        'created_at': insertedAt.toIso8601String(),
        'updated_at': insertedAt.toIso8601String(),
      };

      final current = Patient.fromSupabase(existingRow);
      final updated = current.copyWith(
        doctorReviewPending: false,
        doctorReviewedAt: reviewedAt,
        notes: 'review completed',
        updatedAt: reviewedAt,
      );

      final updatePayload = updated.toSupabase();
      final mergedRow = {
        ...existingRow,
        ...updatePayload,
        'updated_at': reviewedAt.toIso8601String(),
      };

      final afterUpdate = Patient.fromSupabase(mergedRow);

      expect(afterUpdate.doctorReviewPending, isFalse);
      expect(afterUpdate.doctorReviewedAt, equals(reviewedAt));
      expect(afterUpdate.notes, equals('review completed'));
    });
  });
}
