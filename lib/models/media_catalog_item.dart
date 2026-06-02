import 'media_credit.dart';

class MediaCatalogItem {
  const MediaCatalogItem({
    required this.id,
    required this.name,
    required this.categoryId,
    this.posterUrl,
    this.backdropUrl,
    this.containerExtension,
    this.rating,
    this.plot,
    this.genre,
    this.releaseDate,
    this.cast,
    this.role,
    this.credits = const <MediaCredit>[],
    this.director,
    this.directors = const <MediaCredit>[],
    this.tmdbId,
    this.metadataSource,
  });

  final String id;
  final String name;
  final String categoryId;
  final String? posterUrl;
  final String? backdropUrl;
  final String? containerExtension;
  final String? rating;
  final String? plot;
  final String? genre;
  final String? releaseDate;
  final String? cast;
  final String? role;
  final List<MediaCredit> credits;
  final String? director;
  final List<MediaCredit> directors;
  final int? tmdbId;
  final String? metadataSource;

  MediaCatalogItem copyWith({
    String? id,
    String? name,
    String? categoryId,
    String? posterUrl,
    String? backdropUrl,
    String? containerExtension,
    String? rating,
    String? plot,
    String? genre,
    String? releaseDate,
    String? cast,
    String? role,
    List<MediaCredit>? credits,
    String? director,
    List<MediaCredit>? directors,
    int? tmdbId,
    String? metadataSource,
  }) {
    return MediaCatalogItem(
      id: id ?? this.id,
      name: name ?? this.name,
      categoryId: categoryId ?? this.categoryId,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      containerExtension: containerExtension ?? this.containerExtension,
      rating: rating ?? this.rating,
      plot: plot ?? this.plot,
      genre: genre ?? this.genre,
      releaseDate: releaseDate ?? this.releaseDate,
      cast: cast ?? this.cast,
      role: role ?? this.role,
      credits: credits ?? this.credits,
      director: director ?? this.director,
      directors: directors ?? this.directors,
      tmdbId: tmdbId ?? this.tmdbId,
      metadataSource: metadataSource ?? this.metadataSource,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'category_id': categoryId,
      'poster_url': posterUrl,
      'backdrop_url': backdropUrl,
      'container_extension': containerExtension,
      'rating': rating,
      'plot': plot,
      'genre': genre,
      'release_date': releaseDate,
      'cast': cast,
      'role': role,
      'credits': credits.map((credit) => credit.toJson()).toList(),
      'director': director,
      'directors': directors.map((credit) => credit.toJson()).toList(),
      'tmdb_id': tmdbId,
      'metadata_source': metadataSource,
    };
  }

  factory MediaCatalogItem.movieFromJson(Map<String, dynamic> json) {
    return MediaCatalogItem(
      id: _stringFromAny(json['stream_id']),
      name: _stringFromAny(json['name']),
      categoryId: _stringFromAny(json['category_id']),
      posterUrl: _nullableStringFromAny(json['stream_icon']),
      backdropUrl: null,
      containerExtension: _nullableStringFromAny(json['container_extension']),
      metadataSource: 'xtream',
    );
  }

  factory MediaCatalogItem.seriesFromJson(Map<String, dynamic> json) {
    return MediaCatalogItem(
      id: _stringFromAny(json['series_id']),
      name: _stringFromAny(json['name']),
      categoryId: _stringFromAny(json['category_id']),
      posterUrl: _nullableStringFromAny(json['cover']),
      backdropUrl: null,
      metadataSource: 'xtream',
    );
  }

  factory MediaCatalogItem.fromStoredJson(Map<String, dynamic> json) {
    return MediaCatalogItem(
      id: _stringFromAny(json['id']),
      name: _stringFromAny(json['name']),
      categoryId: _stringFromAny(json['category_id']),
      posterUrl: _nullableStringFromAny(json['poster_url']),
      backdropUrl: _nullableStringFromAny(json['backdrop_url']),
      containerExtension: _nullableStringFromAny(json['container_extension']),
      rating: _nullableStringFromAny(json['rating']),
      plot: _nullableStringFromAny(json['plot']),
      genre: _nullableStringFromAny(json['genre']),
      releaseDate: _nullableStringFromAny(json['release_date']),
      cast: _nullableStringFromAny(json['cast']),
      role: _nullableStringFromAny(json['role']),
      credits: _creditsFromStoredJson(json['credits']),
      director: _nullableStringFromAny(json['director']),
      directors: _creditsFromStoredJson(json['directors']),
      tmdbId: _intFromAny(json['tmdb_id']),
      metadataSource: _nullableStringFromAny(json['metadata_source']),
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

List<MediaCredit> _creditsFromStoredJson(Object? value) {
  if (value is! List) {
    return const <MediaCredit>[];
  }
  return value
      .whereType<Map>()
      .map((json) => MediaCredit.fromJson(Map<String, dynamic>.from(json)))
      .where((credit) => credit.name.isNotEmpty)
      .toList(growable: false);
}
