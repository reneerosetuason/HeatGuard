class MobileAccount {
  const MobileAccount({
    required this.id,
    required this.name,
    required this.email,
  });
  final int id;
  final String name;
  final String email;

  factory MobileAccount.fromJson(Map<String, dynamic> json) {
    if (json['email_verified'] != true ||
        json['id'] is! int ||
        json['email'] is! String) {
      throw const FormatException('A verified account is required.');
    }
    return MobileAccount(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      email: json['email'] as String,
    );
  }
}

class RegistrationChallenge {
  const RegistrationChallenge({
    required this.id,
    required this.email,
    required this.resendAfter,
  });
  final String id;
  final String email;
  final int resendAfter;

  factory RegistrationChallenge.fromJson(Map<String, dynamic> json) =>
      RegistrationChallenge(
        id: json['challenge_id'] as String,
        email: json['email'] as String,
        resendAfter: (json['resend_after'] as num?)?.toInt() ?? 60,
      );
}
