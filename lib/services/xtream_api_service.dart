import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/epg_program.dart';
import '../models/live_category.dart';
import '../models/live_stream.dart';

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
    final response = await _dio.get<dynamic>(
      _playerApiUrl(serverUrl),
      queryParameters: {
        'username': username,
        'password': password,
        'action': 'get_live_categories',
      },
    );

    return compute(_parseCategories, _asList(response.data));
  }

  Future<List<LiveStream>> getLiveStreams({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final response = await _dio.get<dynamic>(
      _playerApiUrl(serverUrl),
      queryParameters: {
        'username': username,
        'password': password,
        'action': 'get_live_streams',
      },
    );

    return compute(_parseStreams, _asList(response.data));
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

  String buildLiveStreamUrl({
    required String serverUrl,
    required String username,
    required String password,
    required String streamId,
  }) {
    final normalizedServer = normalizeServerUrl(serverUrl);
    return '$normalizedServer/live/$username/$password/$streamId.ts';
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
