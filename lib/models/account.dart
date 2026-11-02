/// The signed-in Spliit Cloud account, as Better Auth returns it.
class CloudAccount {
  final String id;
  final String name;
  final String email;
  final bool emailVerified;
  final bool isAnonymous;
  final String? image;
  final DateTime? createdAt;

  const CloudAccount({
    required this.id,
    required this.name,
    required this.email,
    this.emailVerified = false,
    this.isAnonymous = false,
    this.image,
    this.createdAt,
  });

  /// Anonymous accounts get a generated placeholder address
  /// (`guest-…@anonymous.placeholder.local`), which is never shown as an
  /// email and cannot receive mail.
  bool get hasRealEmail =>
      email.isNotEmpty && !email.endsWith('@anonymous.placeholder.local');

  String get displayName => name.trim().isNotEmpty ? name : 'Guest';

  CloudAccount copyWithName(String newName) => CloudAccount(
        id: id,
        name: newName,
        email: email,
        emailVerified: emailVerified,
        isAnonymous: isAnonymous,
        image: image,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'emailVerified': emailVerified,
        'isAnonymous': isAnonymous,
        if (image != null) 'image': image,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      };

  factory CloudAccount.fromJson(Map<String, dynamic> json) => CloudAccount(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        emailVerified: json['emailVerified'] as bool? ?? false,
        isAnonymous: json['isAnonymous'] as bool? ?? false,
        image: json['image'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      );
}

/// What `/auth/anonymous-recovery/status` reports for an anonymous account.
class AnonymousRecoveryStatus {
  final bool hasRecoveryKey;
  final bool acknowledged;
  final bool onboardingCompleted;
  final bool hasPasskey;

  const AnonymousRecoveryStatus({
    this.hasRecoveryKey = false,
    this.acknowledged = false,
    this.onboardingCompleted = false,
    this.hasPasskey = false,
  });

  bool get isReady => hasRecoveryKey && acknowledged;

  factory AnonymousRecoveryStatus.fromJson(Map<String, dynamic> json) =>
      AnonymousRecoveryStatus(
        hasRecoveryKey: json['hasRecoveryKey'] as bool? ?? false,
        acknowledged: json['acknowledged'] as bool? ?? false,
        onboardingCompleted: json['onboardingCompleted'] as bool? ?? false,
        hasPasskey: json['hasPasskey'] as bool? ?? false,
      );
}

/// A freshly minted anonymous recovery link.
class AnonymousRecoveryKey {
  final String code;
  final String recoveryUrl;

  const AnonymousRecoveryKey({required this.code, required this.recoveryUrl});

  factory AnonymousRecoveryKey.fromJson(Map<String, dynamic> json) =>
      AnonymousRecoveryKey(
        code: json['code'] as String? ?? '',
        recoveryUrl: json['recoveryUrl'] as String? ?? '',
      );
}
