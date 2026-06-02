class MediaCredit {
  const MediaCredit({
    required this.name,
    this.tmdbId,
    this.role,
    this.profileUrl,
  });

  final String name;
  final int? tmdbId;
  final String? role;
  final String? profileUrl;

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'tmdb_id': tmdbId,
      'role': role,
      'profile_url': profileUrl,
    };
  }

  factory MediaCredit.fromJson(Map<String, dynamic> json) {
    return MediaCredit(
      name: json['name']?.toString() ?? '',
      tmdbId: _intFromAny(json['tmdb_id']),
      role: json['role']?.toString(),
      profileUrl: json['profile_url']?.toString(),
    );
  }
}

int? _intFromAny(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}
