// lib/models/doctor.dart

/// موديل الطبيب.
/// - محليًا (SQLite): مفاتيح camelCase (يتوافق مع DBService).
/// - سحابيًا (Supabase/Postgres): مفاتيح snake_case (يُعالَج تلقائيًا عبر SyncService).
class Doctor {
  static const String table = 'doctors';

  /// تعريف SQL اختياري (محلي). يستخدم camelCase ليتطابق مع DBService.
  static const String createTable = '''
  CREATE TABLE IF NOT EXISTS $table (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    employeeId     INTEGER,
    name           TEXT,
    specialization TEXT,
    phoneNumber    TEXT,
    startTime      TEXT,
    endTime        TEXT,
    userUid        TEXT,
    printCounter   INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (employeeId) REFERENCES employees(id) ON DELETE SET NULL
  );
  ''';

  final int? id;
  final int? employeeId;        // ربط الطبيب بالموظف (اختياري)
  final String name;
  final String specialization;  // التخصص
  final String phoneNumber;
  final String startTime;       // نص (HH:mm أو ISO)
  final String endTime;         // نص (HH:mm أو ISO)
  final String? userUid;        // مرجع مستخدم Supabase (اختياري)
  final int printCounter;       // عدّاد الطباعة (محلي فقط)

  Doctor({
    this.id,
    this.employeeId,
    required this.name,
    required this.specialization,
    required this.phoneNumber,
    required this.startTime,
    required this.endTime,
    this.userUid,
    this.printCounter = 0,
  });

  /* ── Helpers آمنة ── */
  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _toInt0(dynamic v) => _toIntN(v) ?? 0;

  static String _toStr(dynamic v, [String fallback = '']) {
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  /* ── التحويلات ── */
  Map<String, dynamic> toMap() => {
    'id': id,
    'employeeId': employeeId,
    'name': name,
    'specialization': specialization,
    'phoneNumber': phoneNumber,
    'startTime': startTime,
    'endTime': endTime,
    'userUid': userUid,
    'printCounter': printCounter,
  };

  Map<String, dynamic> toJson() => toMap();

  /// يدعم camel + snake (للصفوف القادمة من السحابة عبر SyncService.pull()).
  factory Doctor.fromMap(Map<String, dynamic> map) => Doctor(
    id: _toIntN(map['id']),
    employeeId: _toIntN(map['employeeId'] ?? map['employee_id']),
    name: _toStr(map['name']),
    specialization: _toStr(map['specialization']),
    phoneNumber: _toStr(map['phoneNumber'] ?? map['phone_number']),
    startTime: _toStr(map['startTime'] ?? map['start_time']),
    endTime: _toStr(map['endTime'] ?? map['end_time']),
    userUid: map['userUid']?.toString() ?? map['user_uid']?.toString(),
    printCounter: _toInt0(map['printCounter'] ?? map['print_counter']),
  );

  factory Doctor.fromJson(Map<String, dynamic> json) => Doctor.fromMap(json);

  Doctor copyWith({
    int? id,
    int? employeeId,
    String? name,
    String? specialization,
    String? phoneNumber,
    String? startTime,
    String? endTime,
    String? userUid,
    int? printCounter,
  }) {
    return Doctor(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      name: name ?? this.name,
      specialization: specialization ?? this.specialization,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      userUid: userUid ?? this.userUid,
      printCounter: printCounter ?? this.printCounter,
    );
  }

  @override
  String toString() =>
      'Doctor(id:$id, empId:$employeeId, name:$name, spec:$specialization, user:$userUid, printCounter:$printCounter)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is Doctor &&
              runtimeType == other.runtimeType &&
              id == other.id &&
              employeeId == other.employeeId &&
              name == other.name &&
              specialization == other.specialization &&
              phoneNumber == other.phoneNumber &&
              startTime == other.startTime &&
              endTime == other.endTime &&
              userUid == other.userUid &&
              printCounter == other.printCounter;

  @override
  int get hashCode => Object.hash(
    id,
    employeeId,
    name,
    specialization,
    phoneNumber,
    startTime,
    endTime,
    userUid,
    printCounter,
  );
}
