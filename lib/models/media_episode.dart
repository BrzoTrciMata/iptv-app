class MediaEpisode {
  const MediaEpisode({
    required this.id,
    required this.title,
    required this.seasonNumber,
    required this.episodeNumber,
    this.containerExtension,
    this.imageUrl,
    this.plot,
    this.releaseDate,
    this.rating,
    this.director,
    this.cast,
    this.tmdbId,
  });

  final String id;
  final String title;
  final int seasonNumber;
  final int episodeNumber;
  final String? containerExtension;
  final String? imageUrl;
  final String? plot;
  final String? releaseDate;
  final String? rating;
  final String? director;
  final String? cast;
  final int? tmdbId;

  MediaEpisode copyWith({
    String? id,
    String? title,
    int? seasonNumber,
    int? episodeNumber,
    String? containerExtension,
    String? imageUrl,
    String? plot,
    String? releaseDate,
    String? rating,
    String? director,
    String? cast,
    int? tmdbId,
  }) {
    return MediaEpisode(
      id: id ?? this.id,
      title: title ?? this.title,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      containerExtension: containerExtension ?? this.containerExtension,
      imageUrl: imageUrl ?? this.imageUrl,
      plot: plot ?? this.plot,
      releaseDate: releaseDate ?? this.releaseDate,
      rating: rating ?? this.rating,
      director: director ?? this.director,
      cast: cast ?? this.cast,
      tmdbId: tmdbId ?? this.tmdbId,
    );
  }

  factory MediaEpisode.fromJson(
    Map<String, dynamic> json, {
    int? seasonNumber,
  }) {
    final title = _stringFromAny(json['title']).isNotEmpty
        ? _stringFromAny(json['title'])
        : _stringFromAny(json['name']);

    return MediaEpisode(
      id: _stringFromAny(json['id']),
      title: title,
      seasonNumber: _intFromAny(json['season'] ?? json['season_number']) ??
          seasonNumber ??
          1,
      episodeNumber:
          _intFromAny(json['episode_num'] ?? json['episode_number']) ?? 1,
      containerExtension: _nullableStringFromAny(json['container_extension']),
    );
  }
}

String _stringFromAny(Object? value) => value?.toString().trim() ?? '';

String? _nullableStringFromAny(Object? value) {
  final parsed = _stringFromAny(value);
  return parsed.isEmpty ? null : parsed;
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
