// lib/screens/chat/chat_home_screen.dart
//
// الشاشة الرئيسية للمحادثات للمستخدم النهائي. تعتمد على ChatProvider
// لجلب المحادثات وعرضها مع دعم البحث وتصفية الرسائل غير المقروءة.

import 'dart:ui' as ui show TextDirection;

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/chat_models.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/chat_provider.dart';
import 'package:aelmamclinic/widgets/chat/conversation_tile.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'chat_room_screen.dart';

class ChatHomeScreen extends StatefulWidget {
  const ChatHomeScreen({super.key});

  static const String routeName = '/chat/home';

  @override
  State<ChatHomeScreen> createState() => _ChatHomeScreenState();
}

class _ChatHomeScreenState extends State<ChatHomeScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _unreadOnly = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureBootstrap());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _ensureBootstrap() {
    final chat = context.read<ChatProvider>();
    if (chat.ready || chat.busy) return;
    final auth = context.read<AuthProvider>();
    chat.bootstrap(
      accountId: auth.accountId,
      role: auth.role,
      isSuperAdmin: auth.isSuperAdmin,
    );
  }

  Future<void> _refresh() async {
    await context.read<ChatProvider>().refreshConversations();
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final convs = chat.conversations;
    final query = _searchCtrl.text.trim().toLowerCase();

    final filtered = convs.where((conv) {
      if (_unreadOnly && (conv.unreadCount ?? 0) == 0) {
        return false;
      }
      if (query.isEmpty) return true;
      final title = chat.displayTitleOf(conv.id).toLowerCase();
      final snippet = (conv.lastMsgSnippet ?? '').toLowerCase();
      return title.contains(query) || snippet.contains(query);
    }).toList()
      ..sort((a, b) {
        final aTime = a.lastMsgAt ?? a.updatedAt ?? a.createdAt;
        final bTime = b.lastMsgAt ?? b.updatedAt ?? b.createdAt;
        return bTime.compareTo(aTime);
      });

    final isBusy = chat.busy && !chat.ready;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المحادثات'),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: chat.busy ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _showNewConversationDialog(context),
          tooltip: 'بدء محادثة جديدة',
          child: const Icon(Icons.chat_rounded),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'ابحث باسم الشخص أو محتوى الرسائل',
                          prefixIcon: Icon(Icons.search_rounded),
                          border: OutlineInputBorder(),
                        ),
                        textDirection: ui.TextDirection.rtl,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('غير المقروءة'),
                      avatar: const Icon(Icons.mark_chat_unread_rounded, size: 18),
                      selected: _unreadOnly,
                      onSelected: (value) => setState(() => _unreadOnly = value),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  color: kPrimaryColor,
                  onRefresh: _refresh,
                  child: Builder(
                    builder: (_) {
                      if (isBusy) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (filtered.isEmpty) {
                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            Center(
                              child: Text(
                                'لا توجد محادثات متاحة.',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        );
                      }

                      return ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
                        itemBuilder: (context, index) {
                          final conversation = filtered[index];
                          final displayTitle = chat.displayTitleOf(conversation.id);
                          final snippet = conversation.lastMsgSnippet ?? '';
                          final typing = chat.typingUids(conversation.id);
                          final subtitleOverride = typing.isNotEmpty
                              ? 'جارٍ الكتابة...'
                              : (snippet.trim().isEmpty ? 'لا توجد رسائل بعد' : snippet.trim());

                          return ConversationTile(
                            conversation: conversation,
                            titleOverride: displayTitle,
                            subtitleOverride: subtitleOverride,
                            subtitleIsTyping: typing.isNotEmpty,
                            unreadCount: conversation.unreadCount ?? 0,
                            clinicLabel: null,
                            isMuted: false,
                            isOnline: null,
                            showChevron: true,
                            onTap: () => _openConversation(conversation.id),
                            onLongPress: () =>
                                _showConversationActions(context, conversation),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openConversation(String conversationId) async {
    final chat = context.read<ChatProvider>();
    await chat.openConversation(conversationId);
    await chat.markConversationRead(conversationId);
    if (!mounted) return;
    final conversation = chat.conversations.firstWhere(
      (c) => c.id == conversationId,
      orElse: () => chat.conversations.first,
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(conversation: conversation),
      ),
    );
    if (!mounted) return;
    await chat.refreshConversations();
  }

  Future<void> _showConversationActions(
      BuildContext context, ChatConversation conversation) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.visibility_rounded),
                title: const Text('عرض المحادثة'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openConversation(conversation.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.mark_email_read_rounded),
                title: const Text('تعيين كمقروء'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await context.read<ChatProvider>().markConversationRead(conversation.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showNewConversationDialog(BuildContext context) async {
    final emailCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('بدء محادثة جديدة'),
          content: TextField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              hintText: 'أدخل البريد الإلكتروني',
            ),
            textDirection: ui.TextDirection.ltr,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(emailCtrl.text.trim().toLowerCase()),
              child: const Text('بدء'),
            ),
          ],
        ),
      ),
    );

    if (result == null || result.isEmpty) {
      emailCtrl.dispose();
      return;
    }

    try {
      final chat = context.read<ChatProvider>();
      final conversation =
          await chat.startDirectByEmail(result); // will schedule refresh
      await chat.openConversation(conversation.id);
      await chat.markConversationRead(conversation.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(conversation: conversation),
        ),
      );
      await chat.refreshConversations();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء المحادثة: $e')),
      );
    } finally {
      emailCtrl.dispose();
    }
  }
}
