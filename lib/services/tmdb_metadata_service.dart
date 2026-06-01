import 'package:dio/dio.dart';

import '../models/media_catalog_item.dart';
import '../models/media_episode.dart';

enum TmdbMediaType {
  movie,
  tv,
}

class TmdbMetadataService {
  TmdbMetadataService({
    Dio? dio,
    String? accessToken,
    String? apiKey,
  })  : _accessToken =
            accessToken ?? const String.fromEnvironment('TMDB_ACCESS_TOKEN'),
        _apiKey = apiKey ?? const String.fromEnvironment('TMDB_API_KEY'),
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: 'https://api.themoviedb.org/3',
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 8),
                sendTimeout: const Duration(seconds: 8),
              ),
            );

  static const _imageBaseUrl = 'https://image.tmdb.org/t/p';

  final Dio _dio;
  final String _accessToken;
  final String _apiKey;
  final Map<String, MediaCatalogItem?> _itemCache =
      <String, MediaCatalogItem?>{};
  final Map<int, List<MediaEpisode>> _episodeCache =
      <int, List<MediaEpisode>>{};

  bool get isConfigured => _accessToken.isNotEmpty || _apiKey.isNotEmpty;

  Future<MediaCatalogItem?> enrichItem({
    required MediaCatalogItem item,
    required TmdbMediaType type,
  }) async {
    if (!isConfigured) {
      return null;
    }

    final cacheKey = '${type.name}:${item.id}:${item.name}';
    if (_itemCache.containsKey(cacheKey)) {
      return _itemCache[cacheKey];
    }

    try {
      final searchResult = await _searchBestMatch(item.name, type);
      if (searchResult == null) {
        _itemCache[cacheKey] = null;
        return null;
      }

      final tmdbId = _intFromAny(searchResult['id']);
      if (tmdbId == null) {
        _itemCache[cacheKey] = null;
        return null;
      }

      final details = await _getMap(
        type == TmdbMediaType.movie ? '/movie/$tmdbId' : '/tv/$tmdbId',
        queryParameters: {
          'append_to_response':
              type == TmdbMediaType.movie ? 'credits' : 'aggregate_credits',
        },
      );
      final enriched = _itemFromTmdb(
        item: item,
        details: details,
        type: type,
      );
      _itemCache[cacheKey] = enriched;
      return enriched;
    } catch (_) {
      _itemCache[cacheKey] = null;
      return null;
    }
  }

  Future<List<MediaEpisode>> enrichEpisodes({
    required MediaCatalogItem series,
    required List<MediaEpisode> episodes,
  }) async {
    if (!isConfigured || episodes.isEmpty) {
      return episodes;
    }

    final tmdbId = series.tmdbId ??
        (await enrichItem(item: series, type: TmdbMediaType.tv))?.tmdbId;
    if (tmdbId == null) {
      return episodes;
    }

    final tmdbEpisodes = await _loadTvEpisodes(tmdbId, episodes);
    if (tmdbEpisodes.isEmpty) {
      return episodes;
    }

    return episodes.map((episode) {
      final key = _episodeKey(episode.seasonNumber, episode.episodeNumber);
      final tmdbEpisode = tmdbEpisodes[key];
      if (tmdbEpisode == null) {
        return episode;
      }

      return episode.copyWith(
        title: tmdbEpisode.title,
        imageUrl: tmdbEpisode.imageUrl,
        plot: tmdbEpisode.plot,
        releaseDate: tmdbEpisode.releaseDate,
        rating: tmdbEpisode.rating,
        director: tmdbEpisode.director,
        cast: tmdbEpisode.cast,
        tmdbId: tmdbEpisode.tmdbId,
      );
    }).toList(growable: false);
  }

  Future<Map<String, MediaEpisode>> _loadTvEpisodes(
    int tmdbId,
    List<MediaEpisode> episodes,
  ) async {
    if (_episodeCache.containsKey(tmdbId)) {
      return {
        for (final episode in _episodeCache[tmdbId]!)
          _episodeKey(episode.seasonNumber, episode.episodeNumber): episode,
      };
    }

    final seasons = episodes
        .map((episode) => episode.seasonNumber)
        .toSet()
        .toList(growable: false)
      ..sort();
    final loaded = <MediaEpisode>[];

    for (final season in seasons) {
      try {
        final data = await _getMap(
          '/tv/$tmdbId/season/$season',
          queryParameters: {'append_to_response': 'aggregate_credits'},
        );
        final rawEpisodes = data['episodes'];
        if (rawEpisodes is! List) {
          continue;
        }
        loaded.addAll(
          rawEpisodes
              .map(_asStringMap)
              .nonNulls
              .map((episode) => _episodeFromTmdb(episode, season)),
        );
      } catch (_) {
        continue;
      }
    }

    _episodeCache[tmdbId] = loaded;
    return {
      for (final episode in loaded)
        _episodeKey(episode.seasonNumber, episode.episodeNumber): episode,
    };
  }

  Future<Map<String, dynamic>?> _searchBestMatch(
    String rawName,
    TmdbMediaType type,
  ) async {
    final query = _cleanTitle(rawName);
    if (query.isEmpty) {
      return null;
    }

    final data = await _getMap(
      type == TmdbMediaType.movie ? '/search/movie' : '/search/tv',
      queryParameters: {
        'query': query,
        'include_adult': false,
      },
    );
    final results = data['results'];
    if (results is! List || results.isEmpty) {
      return null;
    }

    final normalizedQuery = _normalizeTitle(query);
    final matches = results.map(_asStringMap).nonNulls.toList(growable: false);
    matches.sort((a, b) {
      final aScore = _matchScore(a, normalizedQuery, type);
      final bScore = _matchScore(b, normalizedQuery, type);
      return bScore.compareTo(aScore);
    });
    return matches.first;
  }

  MediaCatalogItem _itemFromTmdb({
    required MediaCatalogItem item,
    required Map<String, dynamic> details,
    required TmdbMediaType type,
  }) {
    final credits = _asStringMap(
      type == TmdbMediaType.movie
          ? details['credits']
          : details['aggregate_credits'],
    );
    return item.copyWith(
      name: _firstNonEmpty([
            details['title'],
            details['name'],
            details['original_title'],
            details['original_name'],
          ]) ??
          item.name,
      posterUrl: _imageUrl(details['poster_path'], 'w500'),
      backdropUrl: _imageUrl(details['backdrop_path'], 'w1280'),
      rating: _ratingFromAny(details['vote_average']),
      plot: _nullableStringFromAny(details['overview']),
      genre: _genresFromAny(details['genres']),
      releaseDate: _firstNonEmpty([
        details['release_date'],
        details['first_air_date'],
      ]),
      cast: _castFromCredits(credits),
      director: type == TmdbMediaType.movie
          ? _crewFromCredits(credits, {'Director'})
          : _crewFromCredits(credits, {'Creator', 'Executive Producer'}),
      tmdbId: _intFromAny(details['id']),
      metadataSource: 'tmdb',
    );
  }

  MediaEpisode _episodeFromTmdb(Map<String, dynamic> json, int seasonNumber) {
    final credits = _asStringMap(json['credits']) ?? json;
    return MediaEpisode(
      id: _stringFromAny(json['id']),
      title: _nullableStringFromAny(json['name']) ?? 'Episode',
      seasonNumber: _intFromAny(json['season_number']) ?? seasonNumber,
      episodeNumber: _intFromAny(json['episode_number']) ?? 1,
      imageUrl: _imageUrl(json['still_path'], 'w500'),
      plot: _nullableStringFromAny(json['overview']),
      releaseDate: _nullableStringFromAny(json['air_date']),
      rating: _ratingFromAny(json['vote_average']),
      director: _crewFromCredits(credits, {'Director'}),
      cast: _castFromCredits(credits),
      tmdbId: _intFromAny(json['id']),
    );
  }

  Future<Map<String, dynamic>> _getMap(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      path,
      queryParameters: {
        ...?queryParameters,
        if (_apiKey.isNotEmpty) 'api_key': _apiKey,
      },
      options: Options(
        headers: {
          if (_accessToken.isNotEmpty) 'Authorization': 'Bearer $_accessToken',
          'accept': 'application/json',
        },
      ),
    );
    return response.data ?? const <String, dynamic>{};
  }
}

String _cleanTitle(String value) {
  return value
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\([^)]*(19|20)\d{2}[^)]*\)'), ' ')
      .replaceAll(
        RegExp(
          r'\b(4k|uhd|fhd|hd|sd|hevc|x264|x265)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'^[a-z]{2}\s*[-|]\s*', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _normalizeTitle(String value) {
  return _cleanTitle(value).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

double _matchScore(
  Map<String, dynamic> result,
  String normalizedQuery,
  TmdbMediaType type,
) {
  final title = _normalizeTitle(
    _firstNonEmpty([
          result['title'],
          result['name'],
          result['original_title'],
          result['original_name'],
        ]) ??
        '',
  );
  final popularity = _doubleFromAny(result['popularity']) ?? 0;
  final voteCount = _doubleFromAny(result['vote_count']) ?? 0;
  var score = popularity + voteCount / 1000;
  if (title == normalizedQuery) {
    score += 1000;
  } else if (title.contains(normalizedQuery) ||
      normalizedQuery.contains(title)) {
    score += 200;
  }
  return score;
}

String? _imageUrl(Object? path, String size) {
  final parsed = _nullableStringFromAny(path);
  if (parsed == null) {
    return null;
  }
  return '${TmdbMetadataService._imageBaseUrl}/$size$parsed';
}

String? _genresFromAny(Object? value) {
  if (value is! List) {
    return null;
  }
  final genres = value
      .map(_asStringMap)
      .nonNulls
      .map((genre) => _nullableStringFromAny(genre['name']))
      .nonNulls
      .take(4)
      .join(' / ');
  return genres.isEmpty ? null : genres;
}

String? _castFromCredits(Map<String, dynamic>? credits) {
  final rawCast = credits?['cast'] ?? credits?['guest_stars'];
  if (rawCast is! List) {
    return null;
  }
  final cast = rawCast
      .map(_asStringMap)
      .nonNulls
      .map((person) => _nullableStringFromAny(person['name']))
      .nonNulls
      .take(8)
      .join(', ');
  return cast.isEmpty ? null : cast;
}

String? _crewFromCredits(Map<String, dynamic>? credits, Set<String> jobs) {
  final rawCrew = credits?['crew'];
  if (rawCrew is! List) {
    return null;
  }
  final crew = rawCrew
      .map(_asStringMap)
      .nonNulls
      .where((person) {
        final job = _nullableStringFromAny(person['job']);
        final jobsList = person['jobs'];
        return job != null && jobs.contains(job) ||
            jobsList is List &&
                jobsList
                    .map(_asStringMap)
                    .nonNulls
                    .any((item) => jobs.contains(item['job']));
      })
      .map((person) => _nullableStringFromAny(person['name']))
      .nonNulls
      .toSet()
      .take(4)
      .join(', ');
  return crew.isEmpty ? null : crew;
}

String? _ratingFromAny(Object? value) {
  final parsed = _doubleFromAny(value);
  if (parsed == null || parsed <= 0) {
    return null;
  }
  return parsed.toStringAsFixed(1);
}

String _episodeKey(int season, int episode) => '$season:$episode';

String _stringFromAny(Object? value) => value?.toString().trim() ?? '';

String? _nullableStringFromAny(Object? value) {
  final parsed = _stringFromAny(value);
  return parsed.isEmpty ? null : parsed;
}

String? _firstNonEmpty(List<Object?> values) {
  for (final value in values) {
    final parsed = _nullableStringFromAny(value);
    if (parsed != null) {
      return parsed;
    }
  }
  return null;
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

double? _doubleFromAny(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
}

Map<String, dynamic>? _asStringMap(dynamic data) {
  if (data is Map<String, dynamic>) {
    return data;
  }
  if (data is Map) {
    return data.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}
