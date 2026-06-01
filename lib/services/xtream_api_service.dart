import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/epg_program.dart';
import '../models/live_category.dart';
import '../models/live_stream.dart';
import '../models/media_catalog_item.dart';
import '../models/media_episode.dart';

class XtreamApiService {
  XtreamApiService({
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10),
              ),
            );

  final Dio _dio;

  Future<List<LiveCategory>> getLiveCategories({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final data = await _getCachedPlayerApiData(
      serverUrl: serverUrl,
      username: username,
      password: password,
      action: 'get_live_categories',
      maxAge: const Duration(hours: 12),
    );

    return compute(_parseCategories, _asList(data));
  }

  Future<List<LiveStream>> getLiveStreams({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final data = await _getCachedPlayerApiData(
      serverUrl: serverUrl,
      username: username,
      password: password,
      action: 'get_live_streams',
      maxAge: const Duration(hours: 12),
    );

    return compute(_parseStreams, _asList(data));
  }

  Future<List<LiveCategory>> getVodCategories({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final data = await _getCachedPlayerApiData(
      serverUrl: serverUrl,
      username: username,
      password: password,
      action: 'get_vod_categories',
      maxAge: const Duration(days: 7),
    );

    return compute(_parseCategories, _asList(data));
  }

  Future<List<MediaCatalogItem>> getVodStreams({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final data = await _getCachedPlayerApiData(
      serverUrl: serverUrl,
      username: username,
      password: password,
      action: 'get_vod_streams',
      maxAge: const Duration(days: 7),
    );

    return compute(_parseMovies, _asList(data));
  }

  Future<List<LiveCategory>> getSeriesCategories({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final data = await _getCachedPlayerApiData(
      serverUrl: serverUrl,
      username: username,
      password: password,
      action: 'get_series_categories',
      maxAge: const Duration(days: 7),
    );

    return compute(_parseCategories, _asList(data));
  }

  Future<List<MediaCatalogItem>> getSeries({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final data = await _getCachedPlayerApiData(
      serverUrl: serverUrl,
      username: username,
      password: password,
      action: 'get_series',
      maxAge: const Duration(days: 7),
    );

    return compute(_parseSeries, _asList(data));
  }

  Future<List<MediaEpisode>> getSeriesEpisodes({
    required String serverUrl,
    required String username,
    required String password,
    required String seriesId,
  }) async {
    final data = await _getCachedPlayerApiData(
      serverUrl: serverUrl,
      username: username,
      password: password,
      action: 'get_series_info',
      extra: seriesId,
      queryParameters: {'series_id': seriesId},
      maxAge: const Duration(days: 7),
    );

    return compute(_parseSeriesEpisodes, data);
  }

  Future<EpgProgram?> getCurrentEpg({
    required String serverUrl,
    required String username,
    required String password,
    required String streamId,
  }) async {
    final shortEpg = await _getEpgByAction(
      serverUrl: serverUrl,
      username: username,
      password: password,
      streamId: streamId,
      action: 'get_short_epg',
      limit: 5,
    );
    if (shortEpg != null) {
      return shortEpg;
    }

    return _getEpgByAction(
      serverUrl: serverUrl,
      username: username,
      password: password,
      streamId: streamId,
      action: 'get_simple_data_table',
    );
  }

  Future<EpgProgram?> _getEpgByAction({
    required String serverUrl,
    required String username,
    required String password,
    required String streamId,
    required String action,
    int? limit,
  }) async {
    final response = await _dio.get<dynamic>(
      _playerApiUrl(serverUrl),
      queryParameters: {
        'username': username,
        'password': password,
        'action': action,
        'stream_id': streamId,
        if (limit != null) 'limit': limit,
      },
    );

    final data = _decodeJsonIfNeeded(response.data);
    final items = _extractEpgItems(data);
    if (items.isEmpty) {
      return null;
    }

    final programs = items
        .map(_asStringMap)
        .nonNulls
        .map(EpgProgram.fromJson)
        .toList(growable: false);

    return _pickCurrentProgram(programs);
  }

  Future<dynamic> _getCachedPlayerApiData({
    required String serverUrl,
    required String username,
    required String password,
    required String action,
    required Duration maxAge,
    String? extra,
    Map<String, dynamic> queryParameters = const {},
  }) async {
    final cacheKey = _cacheKey(
      serverUrl: serverUrl,
      username: username,
      action: action,
      extra: extra,
    );
    final cached = await _readCachedData(cacheKey, maxAge);
    if (cached != null) {
      return cached;
    }

    final response = await _dio.get<dynamic>(
      _playerApiUrl(serverUrl),
      queryParameters: {
        'username': username,
        'password': password,
        'action': action,
        ...queryParameters,
      },
    );
    unawaited(_writeCachedData(cacheKey, response.data));
    return response.data;
  }

  String buildLiveStreamUrl({
    required String serverUrl,
    required String username,
    required String password,
    required String streamId,
  }) {
    final normalizedServer = normalizeServerUrl(serverUrl);
    return '$normalizedServer/live/$username/$password/$streamId.ts';
  }

  String buildMovieStreamUrl({
    required String serverUrl,
    required String username,
    required String password,
    required String streamId,
    String? extension,
  }) {
    final normalizedServer = normalizeServerUrl(serverUrl);
    final ext = (extension == null || extension.trim().isEmpty)
        ? 'mp4'
        : extension.trim();
    return '$normalizedServer/movie/$username/$password/$streamId.$ext';
  }

  String buildSeriesEpisodeUrl({
    required String serverUrl,
    required String username,
    required String password,
    required String episodeId,
    String? extension,
  }) {
    final normalizedServer = normalizeServerUrl(serverUrl);
    final ext = (extension == null || extension.trim().isEmpty)
        ? 'mp4'
        : extension.trim();
    return '$normalizedServer/series/$username/$password/$episodeId.$ext';
  }

  static String normalizeServerUrl(String value) {
    final trimmed = value.trim();
    final withScheme =
        trimmed.startsWith(RegExp('https?://')) ? trimmed : 'http://$trimmed';
    return withScheme.replaceAll(RegExp(r'/+$'), '');
  }

  static String _playerApiUrl(String serverUrl) {
    return '${normalizeServerUrl(serverUrl)}/player_api.php';
  }
}

Future<dynamic> _readCachedData(String key, Duration maxAge) async {
  try {
    final file = await _cacheFile(key);
    if (!await file.exists()) {
      return null;
    }

    final payload = jsonDecode(await file.readAsString());
    if (payload is! Map) {
      return null;
    }

    final cachedAt = DateTime.tryParse(payload['cachedAt']?.toString() ?? '');
    if (cachedAt == null || DateTime.now().difference(cachedAt) > maxAge) {
      return null;
    }

    return payload['data'];
  } catch (_) {
    return null;
  }
}

Future<void> _writeCachedData(String key, dynamic data) async {
  try {
    final file = await _cacheFile(key);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'cachedAt': DateTime.now().toIso8601String(),
        'data': data,
      }),
      flush: false,
    );
  } catch (_) {
    // Cache is an optimization; API playback should continue if disk writes fail.
  }
}

Future<File> _cacheFile(String key) async {
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  final baseDirectory = Platform.isMacOS
      ? Directory('$home/Library/Application Support/Vestv/cache')
      : Platform.isWindows
          ? Directory(
              '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
              r'\Vestv\cache',
            )
          : Directory('$home/.vestv/cache');
  return File('${baseDirectory.path}/$key.json');
}

String _cacheKey({
  required String serverUrl,
  required String username,
  required String action,
  String? extra,
}) {
  final raw = [
    XtreamApiService.normalizeServerUrl(serverUrl),
    username,
    action,
    if (extra != null) extra,
  ].join('|');
  return _fnv1a64(raw);
}

String _fnv1a64(String value) {
  const mask = 0x7fffffffffffffff;
  var hash = 0xcbf29ce484222325 & mask;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x100000001b3) & mask;
  }
  return hash.toRadixString(16);
}

List<dynamic> _extractEpgItems(dynamic data) {
  final decoded = _decodeJsonIfNeeded(data);
  if (decoded is List) {
    return decoded.toList(growable: false);
  }
  if (decoded is! Map) {
    return <dynamic>[];
  }

  for (final key in [
    'epg_list',
    'epg_listings',
    'programmes',
    'programs',
    'listings',
  ]) {
    final items = _asList(decoded[key]);
    if (items.isNotEmpty) {
      return items;
    }
  }

  return <dynamic>[];
}

EpgProgram? _pickCurrentProgram(List<EpgProgram> programs) {
  if (programs.isEmpty) {
    return null;
  }

  final now = DateTime.now();
  for (final program in programs) {
    final start = program.start;
    final end = program.end;
    if (start != null &&
        end != null &&
        !now.isBefore(start) &&
        now.isBefore(end)) {
      return program;
    }
  }

  return programs.first;
}

List<dynamic> _asList(dynamic data) {
  final decoded = _decodeJsonIfNeeded(data);
  if (decoded is List<dynamic>) {
    return decoded;
  }
  if (decoded is List) {
    return decoded.toList(growable: false);
  }
  return <dynamic>[];
}

dynamic _decodeJsonIfNeeded(dynamic data) {
  if (data is! String) {
    return data;
  }

  final trimmed = data.trim();
  if (trimmed.isEmpty) {
    return data;
  }

  try {
    return jsonDecode(trimmed);
  } catch (_) {
    return data;
  }
}

Map<String, dynamic>? _asStringMap(dynamic data) {
  final decoded = _decodeJsonIfNeeded(data);
  if (decoded is List) {
    return null;
  }
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

List<LiveCategory> _parseCategories(List<dynamic> data) {
  return data
      .map(_asStringMap)
      .nonNulls
      .map(LiveCategory.fromJson)
      .where((category) => category.categoryId.isNotEmpty)
      .toList(growable: false);
}

List<LiveStream> _parseStreams(List<dynamic> data) {
  return data
      .map(_asStringMap)
      .nonNulls
      .map(LiveStream.fromJson)
      .where((stream) => stream.streamId.isNotEmpty)
      .toList(growable: false);
}

List<MediaCatalogItem> _parseMovies(List<dynamic> data) {
  return data
      .map(_asStringMap)
      .nonNulls
      .map(MediaCatalogItem.movieFromJson)
      .where((item) => item.id.isNotEmpty)
      .toList(growable: false);
}

List<MediaCatalogItem> _parseSeries(List<dynamic> data) {
  return data
      .map(_asStringMap)
      .nonNulls
      .map(MediaCatalogItem.seriesFromJson)
      .where((item) => item.id.isNotEmpty)
      .toList(growable: false);
}

List<MediaEpisode> _parseSeriesEpisodes(dynamic data) {
  final decoded = _decodeJsonIfNeeded(data);
  if (decoded is! Map) {
    return <MediaEpisode>[];
  }

  final episodes = decoded['episodes'];
  final rawEpisodes = <({dynamic episode, int? season})>[];
  if (episodes is List) {
    rawEpisodes.addAll(
      episodes.map((episode) => (episode: episode, season: null)),
    );
  } else if (episodes is Map) {
    for (final entry in episodes.entries) {
      final value = entry.value;
      if (value is List) {
        final season = int.tryParse(entry.key.toString());
        rawEpisodes.addAll(
          value.map((episode) => (episode: episode, season: season)),
        );
      }
    }
  }

  return rawEpisodes
      .map(
        (raw) => (
          episode: _asStringMap(raw.episode),
          season: raw.season,
        ),
      )
      .where((raw) => raw.episode != null)
      .map(
        (raw) => MediaEpisode.fromJson(
          raw.episode!,
          seasonNumber: raw.season,
        ),
      )
      .where((episode) => episode.id.isNotEmpty)
      .toList(growable: false);
}
