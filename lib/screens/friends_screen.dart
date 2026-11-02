import 'package:flutter/material.dart';

import '../api/spliit_client.dart';
import '../l10n/context_l10n.dart';
import '../services/error_reporting.dart';
import '../theme.dart';
import '../widgets/bottom_inset.dart';
import '../widgets/error_message.dart';
import '../widgets/group_monogram.dart';
import '../widgets/grouped_section.dart';

/// People this account shares groups with. Cloud derives friendship from
/// shared memberships, so this is read-only: it fills in as groups and
/// invitations are added, no separate contact list to maintain.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, required this.client});

  final SpliitClient client;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  List<CloudFriend> _friends = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final friends = await widget.client.fetchFriends();
      if (!mounted) return;
      setState(() {
        _friends = friends;
        _loading = false;
      });
    } catch (e, st) {
      final error = ErrorReporter.instance
          .report(e, st, operation: 'Loading friends');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.kind == ErrorKind.connection
            ? context.l10n.errorConnection
            : context.l10n.friendsLoadFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.friendsTitle)),
      body: AboveBottomBar(
        child: GroupedScrollClip(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: ErrorMessage(_error!),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_friends.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.friendsEmpty,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                  )
                else
                  GroupedSection(
                    dividerIndent: 56,
                    children: [
                      for (final friend in _friends)
                        ListTile(
                          leading: Monogram(
                            name: friend.name,
                            color: monogramPalette[
                                groupColorIndex(friend.accountId)],
                            radius: 14,
                          ),
                          title: Text(friend.name),
                          subtitle: Text(friend.sharedGroupCount == 1
                              ? l10n.friendsOneSharedGroup
                              : l10n.friendsSharedGroups(
                                  friend.sharedGroupCount)),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
