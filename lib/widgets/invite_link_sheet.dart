import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/context_l10n.dart';
import 'bottom_inset.dart';

/// The invite link, its QR code and a share button, in the same sheet from
/// the group's settings and the group screen.
Future<void> showInviteLinkSheet(
  BuildContext context, {
  required String inviteUrl,
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _InviteLinkSheet(inviteUrl: inviteUrl, title: title),
  );
}

class _InviteLinkSheet extends StatelessWidget {
  const _InviteLinkSheet({required this.inviteUrl, this.title});

  final String inviteUrl;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      padding: withBottomInset(context, const EdgeInsets.fromLTRB(20, 0, 20, 20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title ?? l10n.groupSettingsInviteTitle,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: inviteUrl,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
                semanticsLabel: l10n.groupSettingsInviteQr,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(inviteUrl, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.share_outlined),
            label: Text(l10n.recoveryShare),
            onPressed: () => SharePlus.instance.share(
                ShareParams(text: inviteUrl, subject: l10n.groupSettingsInviteTitle)),
          ),
        ],
      ),
    );
  }
}
