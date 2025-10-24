part of db_service;

class PatientLocalRepository {
  PatientLocalRepository.test(this._dbService);

  PatientLocalRepository(this._dbService);

  final DBService _dbService;

  Future<int> insertPatient(Patient patient) async {
    final db = await _dbService.database;
    final id = await db.insert('patients', patient.toMap());
    await _dbService._markChanged('patients');
    return id;
  }

  Future<List<Patient>> getAllPatients() async {
    final db = await _dbService.database;
    final rows = await db.rawQuery('''
      SELECT
        p.*,
        d.name AS doctorName,
        d.specialization AS doctorSpecialization
      FROM patients p
      LEFT JOIN doctors d ON d.id = p.doctorId
      WHERE ifnull(p.isDeleted,0)=0
      ORDER BY p.registerDate DESC
    ''');
    return rows
        .map((row) => Patient.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<int> updatePatient(
    Patient patient,
    List<PatientService> newServices,
  ) async {
    final db = await _dbService.database;
    final count = await db.update(
      'patients',
      patient.toMap(),
      where: 'id = ?',
      whereArgs: [patient.id],
    );

    if (patient.id != null) {
      await _dbService.deletePatientServices(patient.id!);
      for (final service in newServices) {
        final toInsert = (service.patientId == patient.id)
            ? service
            : service.copyWith(patientId: patient.id);
        await _dbService.insertPatientService(toInsert);
      }
    }

    await _dbService._markChanged('patients');
    return count;
  }

  Future<int> deletePatient(int id) async {
    final db = await _dbService.database;
    final count = await db.update(
      'patients',
      {'isDeleted': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _dbService._markChanged('patients');
    return count;
  }
}
