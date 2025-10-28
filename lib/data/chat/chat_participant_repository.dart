import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/domain/chat/models/chat_participant.dart';

typedef ChatParticipantUpsertRunner = Future<void> Function(
  Map<String, dynamic> values,
);
typedef ChatParticipantUpdateRunner = Future<void> Function(
  Map<String, dynamic> values,
  Map<String, dynamic> match,
);

/// Repository responsible for preparing and pushing chat participant rows.
class ChatParticipantRepository {
  ChatParticipantRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  PostgrestQueryBuilder get _table =>
      _client.from(ChatParticipantFields.table);

  /// Columns that should be requested from Supabase when loading participants.
  List<String> get remoteColumns => ChatParticipantFields.remoteColumns;

  /// Creates or updates a participant row.
  Future<void> save(
    Map<String, dynamic> participant, {
    ChatParticipantUpsertRunner? runUpsert,
  }) async {
    final payload = ChatParticipantMapper.toRemote(participant);
    final runner = runUpsert ?? _defaultUpsertRunner;
    await runner(payload);
  }

  /// Toggles the pinned state for a participant.
  Future<void> setPinned({
    required String conversationId,
    required String userUid,
    required bool pinned,
    ChatParticipantUpdateRunner? runUpdate,
  }) async {
    await _updateFlags(
      conversationId: conversationId,
      userUid: userUid,
      values: ChatParticipantMapper.pinnedPatch(pinned),
      runUpdate: runUpdate,
    );
  }

  /// Toggles the archived state for a participant.
  Future<void> setArchived({
    required String conversationId,
    required String userUid,
    required bool archived,
    ChatParticipantUpdateRunner? runUpdate,
  }) async {
    await _updateFlags(
      conversationId: conversationId,
      userUid: userUid,
      values: ChatParticipantMapper.archivedPatch(archived),
      runUpdate: runUpdate,
    );
  }

  /// Updates the `last_read_at` timestamp for a participant.
  Future<void> updateLastReadAt({
    required String conversationId,
    required String userUid,
    DateTime? timestamp,
    ChatParticipantUpdateRunner? runUpdate,
  }) async {
    await _updateFlags(
      conversationId: conversationId,
      userUid: userUid,
      values: ChatParticipantMapper.lastReadPatch(timestamp),
      runUpdate: runUpdate,
    );
  }

  Future<void> _defaultUpsertRunner(Map<String, dynamic> values) async {
    await _table.upsert(
      values,
      onConflict:
          '${ChatParticipantFields.conversationId}, ${ChatParticipantFields.userUid}',
      returning: ReturningOption.minimal,
    );
  }

  Future<void> _defaultUpdateRunner(
    Map<String, dynamic> values,
    Map<String, dynamic> match,
  ) async {
    final builder = _table.update(
      values,
      returning: ReturningOption.minimal,
    );
    await builder.match(match);
  }

  Future<void> _updateFlags({
    required String conversationId,
    required String userUid,
    required Map<String, dynamic> values,
    ChatParticipantUpdateRunner? runUpdate,
  }) async {
    final trimmedConversation = conversationId.trim();
    final trimmedUser = userUid.trim();
    if (trimmedConversation.isEmpty) {
      throw ArgumentError.value(conversationId, 'conversationId', 'must not be empty');
    }
    if (trimmedUser.isEmpty) {
      throw ArgumentError.value(userUid, 'userUid', 'must not be empty');
    }

    final runner = runUpdate ?? _defaultUpdateRunner;
    final match = <String, dynamic>{
      ChatParticipantFields.conversationId: trimmedConversation,
      ChatParticipantFields.userUid: trimmedUser,
    };
    await runner(values, match);
  }
}
