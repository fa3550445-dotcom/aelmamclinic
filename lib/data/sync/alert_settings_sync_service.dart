import 'package:aelmamclinic/domain/alerts/models/alert_settings.dart';

/// Provides conversion helpers for syncing `alert_settings` rows with Supabase.
class AlertSettingsSyncService {
  const AlertSettingsSyncService._();

  /// Prepares a local row before pushing it to Supabase.
  static Map<String, dynamic> toCloudMap(Map<String, dynamic> localRow) =>
      AlertSettingsMapper.toCloudMap(localRow);

  /// Normalises a Supabase row before saving it locally.
  static Map<String, dynamic> fromCloudMap(
    Map<String, dynamic> remoteRow,
    Set<String> allowedLocalColumns,
  ) =>
      AlertSettingsMapper.fromCloudMap(remoteRow, allowedLocalColumns);
}
