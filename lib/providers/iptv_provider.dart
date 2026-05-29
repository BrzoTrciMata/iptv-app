import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/epg_program.dart';
import '../models/live_category.dart';
import '../models/live_stream.dart';
import '../services/xtream_api_service.dart';

enum ChannelView {
  category,
  favorites,
  recent,
}

class IptvProvider extends ChangeNotifier {
  IptvProvider({
    XtreamApiService? apiService,
  }) : _apiService = apiService ?? XtreamApiService();

  final XtreamApiService _apiService;

  List<LiveCategory> _categories = <LiveCategory>[];
  List<LiveStream> _streams = <LiveStream>[];
  LiveCategory? _selectedCategory;
  LiveStream? _selectedStream;
  ChannelView _channelView = ChannelView.category;
  Set<String> _favoriteStreamIds = <String>{};
  List<String> _recentStreamIds = <String>[];
  String _searchQuery = '';
  bool _searchAllChannels = false;
  String? _playerUrl;
  bool _isLoading = false;
  String? _errorMessage;
  String? _lastStreamId;
  String? _lastCategoryId;
  final Map<String, EpgProgram?> _epgByStreamId = <String, EpgProgram?>{};
  final Set<String> _loadingEpgStreamIds = <String>{};

  List<LiveCategory> get categories => _categories;
  LiveCategory? get selectedCategory => _selectedCategory;
  LiveStream? get selectedStream => _selectedStream;
  ChannelView get channelView => _channelView;
  Set<String> get favoriteStreamIds => _favoriteStreamIds;
  int get favoritesCount => _favoriteStreamIds.length;
  int get recentCount => _recentStreamIds.length;
  String get searchQuery => _searchQuery;
  bool get searchAllChannels => _searchAllChannels;
  String? get playerUrl => _playerUrl;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

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

      _categories = await categoriesRequest;
      _streams = await streamsRequest;
      await _loadSavedLists();
      _channelView = ChannelView.favorites;
      _restoreLastSelection(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
    } catch (error) {
      _errorMessage = 'Nije moguce ucitati IPTV podatke. Provjerite login.';
    } finally {
      _isLoading = false;
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
    _selectedCategory = null;
    _selectedStream = null;
    _channelView = ChannelView.category;
    _favoriteStreamIds = <String>{};
    _recentStreamIds = <String>[];
    _lastStreamId = null;
    _lastCategoryId = null;
    _epgByStreamId.clear();
    _loadingEpgStreamIds.clear();
    _searchQuery = '';
    _searchAllChannels = false;
    _playerUrl = null;
    _isLoading = false;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _loadSavedLists() async {
    final prefs = await SharedPreferences.getInstance();
    _favoriteStreamIds =
        prefs.getStringList('favorite_stream_ids')?.toSet() ?? <String>{};
    _recentStreamIds = prefs.getStringList('recent_stream_ids') ?? <String>[];
    _lastStreamId = prefs.getString('last_stream_id');
    _lastCategoryId = prefs.getString('last_category_id');
  }

  void _restoreLastSelection({
    required String serverUrl,
    required String username,
    required String password,
  }) {
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
    _playerUrl = _apiService.buildLiveStreamUrl(
      serverUrl: serverUrl,
      username: username,
      password: password,
      streamId: restoredStream.streamId,
    );
    _addRecentStream(restoredStream.streamId);
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
}
