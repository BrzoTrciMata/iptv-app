import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/epg_program.dart';
import '../models/live_category.dart';
import '../models/live_stream.dart';
import '../models/media_catalog_item.dart';
import '../models/media_episode.dart';
import '../models/watch_progress.dart';
import '../services/tmdb_metadata_service.dart';
import '../services/xtream_api_service.dart';

enum ChannelView {
  category,
  favorites,
  recent,
}

class IptvProvider extends ChangeNotifier {
  IptvProvider({
    XtreamApiService? apiService,
    TmdbMetadataService? metadataService,
  })  : _apiService = apiService ?? XtreamApiService(),
        _metadataService = metadataService ?? TmdbMetadataService();

  final XtreamApiService _apiService;
  final TmdbMetadataService _metadataService;

  List<LiveCategory> _categories = <LiveCategory>[];
  List<LiveStream> _streams = <LiveStream>[];
  List<LiveCategory> _movieCategories = <LiveCategory>[];
  List<MediaCatalogItem> _movies = <MediaCatalogItem>[];
  List<LiveCategory> _seriesCategories = <LiveCategory>[];
  List<MediaCatalogItem> _series = <MediaCatalogItem>[];
  LiveCategory? _selectedCategory;
  LiveStream? _selectedStream;
  MediaCatalogItem? _selectedMovie;
  MediaCatalogItem? _selectedSeries;
  ChannelView _channelView = ChannelView.category;
  Set<String> _favoriteStreamIds = <String>{};
  List<String> _recentStreamIds = <String>[];
  List<WatchProgress> _watchHistory = <WatchProgress>[];
  final Map<String, List<MediaEpisode>> _seriesEpisodesById =
      <String, List<MediaEpisode>>{};
  final Set<String> _loadingSeriesEpisodeIds = <String>{};
  String _searchQuery = '';
  bool _searchAllChannels = false;
  String? _playerUrl;
  bool _isLoading = false;
  bool _isMoviesLoading = false;
  bool _isSeriesLoading = false;
  String? _errorMessage;
  String? _movieErrorMessage;
  String? _seriesErrorMessage;
  String? _lastStreamId;
  String? _lastCategoryId;
  final Map<String, EpgProgram?> _epgByStreamId = <String, EpgProgram?>{};
  final Set<String> _loadingEpgStreamIds = <String>{};

  List<LiveCategory> get categories => _categories;
  List<LiveStream> get streams => _streams;
  List<LiveCategory> get movieCategories => _movieCategories;
  List<MediaCatalogItem> get movies => _movies;
  List<LiveCategory> get seriesCategories => _seriesCategories;
  List<MediaCatalogItem> get series => _series;
  LiveCategory? get selectedCategory => _selectedCategory;
  LiveStream? get selectedStream => _selectedStream;
  MediaCatalogItem? get selectedMovie => _selectedMovie;
  MediaCatalogItem? get selectedSeries => _selectedSeries;
  ChannelView get channelView => _channelView;
  Set<String> get favoriteStreamIds => _favoriteStreamIds;
  int get favoritesCount => _favoriteStreamIds.length;
  int get recentCount => _recentStreamIds.length;
  List<WatchProgress> get watchHistory => _watchHistory;
  String get searchQuery => _searchQuery;
  bool get searchAllChannels => _searchAllChannels;
  String? get playerUrl => _playerUrl;
  bool get isLoading => _isLoading;
  bool get isMoviesLoading => _isMoviesLoading;
  bool get isSeriesLoading => _isSeriesLoading;
  String? get errorMessage => _errorMessage;
  String? get movieErrorMessage => _movieErrorMessage;
  String? get seriesErrorMessage => _seriesErrorMessage;
  bool get hasTmdbMetadata => _metadataService.isConfigured;

  List<WatchProgress> watchHistoryFor(String section) {
    return _watchHistory
        .where((progress) => progress.section == section)
        .toList(growable: false);
  }

  List<MediaEpisode> seriesEpisodesFor(String seriesId) {
    return _seriesEpisodesById[seriesId] ?? const <MediaEpisode>[];
  }

  MediaCatalogItem? latestMediaItem({
    required String id,
    required bool isMovie,
  }) {
    final items = isMovie ? _movies : _series;
    return items.where((item) => item.id == id).firstOrNull;
  }

  bool isLoadingSeriesEpisodes(String seriesId) {
    return _loadingSeriesEpisodeIds.contains(seriesId);
  }

  EpgProgram? epgForStream(String streamId) => _epgByStreamId[streamId];

  bool isEpgLoading(String streamId) => _loadingEpgStreamIds.contains(streamId);

  List<LiveStream> get filteredStreams {
    final categoryId = _selectedCategory?.categoryId;
    final query = _searchQuery.toLowerCase().trim();

    return _streams.where((stream) {
      final matchesView = switch (_channelView) {
        ChannelView.favorites => _favoriteStreamIds.contains(stream.streamId),
        ChannelView.recent => _recentStreamIds.contains(stream.streamId),
        ChannelView.category => _searchAllChannels ||
            categoryId == null ||
            stream.categoryId == categoryId,
      };
      final matchesSearch =
          query.isEmpty || stream.name.toLowerCase().contains(query);
      return matchesView && matchesSearch;
    }).toList(growable: false)
      ..sort((a, b) {
        if (_channelView != ChannelView.recent) {
          return 0;
        }
        return _recentStreamIds
            .indexOf(a.streamId)
            .compareTo(_recentStreamIds.indexOf(b.streamId));
      });
  }

  Future<void> loadContent({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final categoriesRequest = _apiService.getLiveCategories(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      final streamsRequest = _apiService.getLiveStreams(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );

      final results = await Future.wait([
        categoriesRequest,
        streamsRequest,
      ]);
      _categories = results[0] as List<LiveCategory>;
      _streams = results[1] as List<LiveStream>;
      await _loadSavedLists();
      _channelView = ChannelView.favorites;
      _restoreLastSelection();
    } catch (error) {
      _errorMessage = 'Nije moguce ucitati IPTV podatke. Provjerite login.';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> ensureMoviesLoaded({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    if (_movies.isNotEmpty || _isMoviesLoading) {
      return;
    }

    _isMoviesLoading = true;
    _movieErrorMessage = null;
    notifyListeners();

    try {
      final movieCategoriesRequest = _apiService.getVodCategories(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      final moviesRequest = _apiService.getVodStreams(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );

      final results = await Future.wait([
        movieCategoriesRequest,
        moviesRequest,
      ]);
      _movieCategories = results[0] as List<LiveCategory>;
      _movies = results[1] as List<MediaCatalogItem>;
    } catch (_) {
      _movieErrorMessage = 'Nije moguce ucitati filmove.';
    } finally {
      _isMoviesLoading = false;
      notifyListeners();
    }
  }

  Future<void> ensureSeriesLoaded({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    if (_series.isNotEmpty || _isSeriesLoading) {
      return;
    }

    _isSeriesLoading = true;
    _seriesErrorMessage = null;
    notifyListeners();

    try {
      final seriesCategoriesRequest = _apiService.getSeriesCategories(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      final seriesRequest = _apiService.getSeries(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );

      final results = await Future.wait([
        seriesCategoriesRequest,
        seriesRequest,
      ]);
      _seriesCategories = results[0] as List<LiveCategory>;
      _series = results[1] as List<MediaCatalogItem>;
    } catch (_) {
      _seriesErrorMessage = 'Nije moguce ucitati serije.';
    } finally {
      _isSeriesLoading = false;
      notifyListeners();
    }
  }

  void selectCategory(LiveCategory category) {
    _channelView = ChannelView.category;
    _selectedCategory = category;
    notifyListeners();
  }

  void selectFavorites() {
    _channelView = ChannelView.favorites;
    notifyListeners();
  }

  void selectRecent() {
    _channelView = ChannelView.recent;
    notifyListeners();
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    notifyListeners();
  }

  void setSearchAllChannels(bool value) {
    _searchAllChannels = value;
    notifyListeners();
  }

  void selectStream({
    required LiveStream stream,
    required String serverUrl,
    required String username,
    required String password,
  }) {
    _selectedStream = stream;
    _selectedCategory = _categories
        .where((category) => category.categoryId == stream.categoryId)
        .firstOrNull;
    _channelView = ChannelView.category;
    _addRecentStream(stream.streamId);
    _lastStreamId = stream.streamId;
    _lastCategoryId = stream.categoryId;
    unawaited(_saveLastSelection());
    _playerUrl = _apiService.buildLiveStreamUrl(
      serverUrl: serverUrl,
      username: username,
      password: password,
      streamId: stream.streamId,
    );
    notifyListeners();
  }

  Future<void> toggleFavorite(LiveStream stream) async {
    if (_favoriteStreamIds.contains(stream.streamId)) {
      _favoriteStreamIds = {..._favoriteStreamIds}..remove(stream.streamId);
    } else {
      _favoriteStreamIds = {..._favoriteStreamIds, stream.streamId};
    }
    notifyListeners();
    await _saveFavoriteIds();
  }

  void selectMovie({
    required MediaCatalogItem movie,
    required String serverUrl,
    required String username,
    required String password,
  }) {
    _selectedMovie = movie;
    _playerUrl = _apiService.buildMovieStreamUrl(
      serverUrl: serverUrl,
      username: username,
      password: password,
      streamId: movie.id,
      extension: movie.containerExtension,
    );
    notifyListeners();
  }

  Future<MediaCatalogItem> enrichMediaMetadata({
    required MediaCatalogItem item,
    required bool isMovie,
  }) async {
    final enriched = await _metadataService.enrichItem(
      item: item,
      type: isMovie ? TmdbMediaType.movie : TmdbMediaType.tv,
    );
    if (enriched == null) {
      return item;
    }

    if (isMovie) {
      _movies = _replaceMediaItem(_movies, enriched);
      if (_selectedMovie?.id == enriched.id) {
        _selectedMovie = enriched;
      }
    } else {
      _series = _replaceMediaItem(_series, enriched);
      if (_selectedSeries?.id == enriched.id) {
        _selectedSeries = enriched;
      }
    }

    _watchHistory = _watchHistory
        .map(
          (progress) => progress.item.id == enriched.id
              ? WatchProgress(
                  section: progress.section,
                  item: enriched,
                  position: progress.position,
                  duration: progress.duration,
                  updatedAt: progress.updatedAt,
                )
              : progress,
        )
        .toList(growable: false);
    notifyListeners();
    return enriched;
  }

  Future<bool> selectSeries({
    required MediaCatalogItem series,
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _selectedSeries = series;
    notifyListeners();

    try {
      final episodes = await _apiService.getSeriesEpisodes(
        serverUrl: serverUrl,
        username: username,
        password: password,
        seriesId: series.id,
      );
      if (episodes.isEmpty) {
        return false;
      }
      final episode = episodes.first;
      _playerUrl = _apiService.buildSeriesEpisodeUrl(
        serverUrl: serverUrl,
        username: username,
        password: password,
        episodeId: episode.id,
        extension: episode.containerExtension,
      );
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  void selectSeriesEpisode({
    required MediaCatalogItem series,
    required MediaEpisode episode,
    required String serverUrl,
    required String username,
    required String password,
  }) {
    _selectedSeries = series;
    _playerUrl = _apiService.buildSeriesEpisodeUrl(
      serverUrl: serverUrl,
      username: username,
      password: password,
      episodeId: episode.id,
      extension: episode.containerExtension,
    );
    notifyListeners();
  }

  Future<void> loadSeriesEpisodes({
    required MediaCatalogItem series,
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    if (_seriesEpisodesById.containsKey(series.id) ||
        _loadingSeriesEpisodeIds.contains(series.id)) {
      return;
    }

    _loadingSeriesEpisodeIds.add(series.id);
    notifyListeners();

    try {
      final xtreamEpisodes = await _apiService.getSeriesEpisodes(
        serverUrl: serverUrl,
        username: username,
        password: password,
        seriesId: series.id,
      );
      final enrichedSeries = await enrichMediaMetadata(
        item: series,
        isMovie: false,
      );
      final episodes = await _metadataService.enrichEpisodes(
        series: enrichedSeries,
        episodes: xtreamEpisodes,
      );
      _seriesEpisodesById[series.id] = episodes;
    } catch (_) {
      _seriesEpisodesById[series.id] = const <MediaEpisode>[];
    } finally {
      _loadingSeriesEpisodeIds.remove(series.id);
      notifyListeners();
    }
  }

  WatchProgress? watchProgressFor({
    required String section,
    required MediaCatalogItem item,
  }) {
    return _watchHistory
        .where(
          (progress) =>
              progress.section == section && progress.item.id == item.id,
        )
        .firstOrNull;
  }

  void markMediaOpened({
    required String section,
    required MediaCatalogItem item,
  }) {
    final existing = watchProgressFor(section: section, item: item);
    _upsertWatchProgress(
      WatchProgress(
        section: section,
        item: item,
        position: existing?.position ?? Duration.zero,
        duration: existing?.duration ?? Duration.zero,
        updatedAt: DateTime.now(),
      ),
    );
  }

  void updateMediaProgress({
    required String section,
    required MediaCatalogItem item,
    required Duration position,
    required Duration duration,
  }) {
    if (position < const Duration(seconds: 3)) {
      return;
    }

    _upsertWatchProgress(
      WatchProgress(
        section: section,
        item: item,
        position: position,
        duration: duration,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> loadEpgForStream({
    required LiveStream stream,
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    if (_epgByStreamId.containsKey(stream.streamId) ||
        _loadingEpgStreamIds.contains(stream.streamId)) {
      return;
    }

    _loadingEpgStreamIds.add(stream.streamId);
    notifyListeners();

    try {
      _epgByStreamId[stream.streamId] = await _apiService.getCurrentEpg(
        serverUrl: serverUrl,
        username: username,
        password: password,
        streamId: stream.streamId,
      );
    } catch (_) {
      _epgByStreamId[stream.streamId] = null;
    } finally {
      _loadingEpgStreamIds.remove(stream.streamId);
      notifyListeners();
    }
  }

  void reset() {
    _categories = <LiveCategory>[];
    _streams = <LiveStream>[];
    _movieCategories = <LiveCategory>[];
    _movies = <MediaCatalogItem>[];
    _seriesCategories = <LiveCategory>[];
    _series = <MediaCatalogItem>[];
    _selectedCategory = null;
    _selectedStream = null;
    _selectedMovie = null;
    _selectedSeries = null;
    _channelView = ChannelView.category;
    _favoriteStreamIds = <String>{};
    _recentStreamIds = <String>[];
    _watchHistory = <WatchProgress>[];
    _seriesEpisodesById.clear();
    _loadingSeriesEpisodeIds.clear();
    _lastStreamId = null;
    _lastCategoryId = null;
    _epgByStreamId.clear();
    _loadingEpgStreamIds.clear();
    _searchQuery = '';
    _searchAllChannels = false;
    _playerUrl = null;
    _isLoading = false;
    _isMoviesLoading = false;
    _isSeriesLoading = false;
    _errorMessage = null;
    _movieErrorMessage = null;
    _seriesErrorMessage = null;
    notifyListeners();
  }

  Future<void> _loadSavedLists() async {
    final prefs = await SharedPreferences.getInstance();
    _favoriteStreamIds =
        prefs.getStringList('favorite_stream_ids')?.toSet() ?? <String>{};
    _recentStreamIds = prefs.getStringList('recent_stream_ids') ?? <String>[];
    _watchHistory = _decodeWatchHistory(
      prefs.getStringList('media_watch_history') ?? const <String>[],
    );
    _lastStreamId = prefs.getString('last_stream_id');
    _lastCategoryId = prefs.getString('last_category_id');
  }

  void _restoreLastSelection() {
    final restoredStream = _streams
        .where((stream) => stream.streamId == _lastStreamId)
        .firstOrNull;

    if (restoredStream == null) {
      _selectedCategory = _categories
          .where((category) => category.categoryId == _lastCategoryId)
          .firstOrNull;
      _selectedCategory ??= _categories.isEmpty ? null : _categories.first;
      return;
    }

    _selectedStream = restoredStream;
    _selectedCategory = _categories
        .where((category) => category.categoryId == restoredStream.categoryId)
        .firstOrNull;
    _selectedCategory ??= _categories.isEmpty ? null : _categories.first;
    _channelView = _favoriteStreamIds.contains(restoredStream.streamId)
        ? ChannelView.favorites
        : ChannelView.category;
    _playerUrl = null;
  }

  Future<void> _saveFavoriteIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'favorite_stream_ids',
      _favoriteStreamIds.toList(growable: false),
    );
  }

  Future<void> _saveRecentIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recent_stream_ids', _recentStreamIds);
  }

  Future<void> _saveLastSelection() async {
    final prefs = await SharedPreferences.getInstance();
    final streamId = _lastStreamId;
    final categoryId = _lastCategoryId;
    if (streamId != null) {
      await prefs.setString('last_stream_id', streamId);
    }
    if (categoryId != null) {
      await prefs.setString('last_category_id', categoryId);
    }
  }

  void _addRecentStream(String streamId) {
    _recentStreamIds = [
      streamId,
      ..._recentStreamIds.where((id) => id != streamId),
    ].take(40).toList(growable: false);
    unawaited(_saveRecentIds());
  }

  void _upsertWatchProgress(WatchProgress progress) {
    _watchHistory = [
      progress,
      ..._watchHistory.where(
        (item) =>
            item.section != progress.section ||
            item.item.id != progress.item.id,
      ),
    ].take(60).toList(growable: false);
    notifyListeners();
    unawaited(_saveWatchHistory());
  }

  Future<void> _saveWatchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'media_watch_history',
      _watchHistory.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  List<WatchProgress> _decodeWatchHistory(List<String> encodedItems) {
    final history = <WatchProgress>[];
    for (final encodedItem in encodedItems) {
      try {
        history.add(
          WatchProgress.fromJson(
            Map<String, dynamic>.from(jsonDecode(encodedItem) as Map),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return history;
  }
}

List<MediaCatalogItem> _replaceMediaItem(
  List<MediaCatalogItem> items,
  MediaCatalogItem replacement,
) {
  return items
      .map((item) => item.id == replacement.id ? replacement : item)
      .toList(growable: false);
}
