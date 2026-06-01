import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/epg_program.dart';
import '../models/live_category.dart';
import '../models/live_stream.dart';
import '../models/media_catalog_item.dart';
import '../models/media_episode.dart';
import '../models/watch_progress.dart';
import '../providers/auth_provider.dart';
import '../providers/iptv_provider.dart';

enum _PlayerDisplayMode {
  normal,
  window,
  fullscreen,
}

enum _SearchScope {
  categories,
  channels,
}

enum _LibrarySection {
  live,
  movies,
  series,
}

String _mediaSectionKey(_LibrarySection section) {
  return switch (section) {
    _LibrarySection.movies => 'movies',
    _LibrarySection.series => 'series',
    _LibrarySection.live => 'live',
  };
}

FCardStyleDelta _darkCardStyle(
  BuildContext context, {
  bool selected = false,
  bool hovered = false,
  bool borderless = false,
}) {
  final colors = context.theme.colors;
  return FCardStyleDelta.delta(
    decoration: DecorationDelta.boxDelta(
      color: selected
          ? const Color(0xFF12302D)
          : hovered
              ? const Color(0xFF1B2423)
              : const Color(0xFF111417),
      border: borderless
          ? null
          : Border.all(
              color: selected
                  ? colors.primary.withValues(alpha: 0.38)
                  : hovered
                      ? colors.primary.withValues(alpha: 0.42)
                      : Colors.white.withValues(alpha: 0.07),
            ),
      borderRadius: context.theme.style.borderRadius.md,
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WindowListener {
  late final Player _player;
  late final VideoController _videoController;
  final FocusNode _keyboardFocusNode = FocusNode();
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  String? _activeUrl;
  String? _suppressedPlayerUrl;
  String? _playerError;
  MediaCatalogItem? _activeMediaItem;
  String? _activeMediaSectionKey;
  MediaCatalogItem? _mediaDetailItem;
  _LibrarySection? _mediaDetailSection;
  Duration? _pendingResumePosition;
  DateTime? _lastProgressSavedAt;
  bool _searchOpen = false;
  _LibrarySection? _mediaSearchSection;
  _LibrarySection _librarySection = _LibrarySection.live;
  _PlayerDisplayMode _playerDisplayMode = _PlayerDisplayMode.normal;
  bool _activePlaybackIsLive = true;
  String? _activePlaybackTitle;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _player = Player();
    _videoController = VideoController(_player);
    _errorSubscription = _player.stream.error.listen((error) {
      if (!mounted) {
        return;
      }
      setState(() => _playerError = error);
    });
    _positionSubscription = _player.stream.position.listen(
      _saveMediaProgressFromPlayer,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardFocusNode.requestFocus();
      final auth = context.read<AuthProvider>();
      context.read<IptvProvider>().loadContent(
            serverUrl: auth.serverUrl!,
            username: auth.username!,
            password: auth.password!,
          );
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    windowManager.removeListener(this);
    _errorSubscription?.cancel();
    _positionSubscription?.cancel();
    _player.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  @override
  void onWindowFocus() {
    _keyboardFocusNode.requestFocus();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (_playerDisplayMode == _PlayerDisplayMode.fullscreen && mounted) {
      unawaited(_exitPlayerDisplayMode());
    }
  }

  Future<void> _setPlayerDisplayMode(_PlayerDisplayMode mode) async {
    await windowManager.setFullScreen(mode == _PlayerDisplayMode.fullscreen);
    if (mounted) {
      setState(() => _playerDisplayMode = mode);
    }
  }

  Future<void> _exitPlayerDisplayMode() async {
    await _closeActivePlayer();
  }

  Future<void> _toggleWindowPlayerMode() {
    if (_playerDisplayMode == _PlayerDisplayMode.window) {
      return _exitPlayerDisplayMode();
    }
    return _setPlayerDisplayMode(
      _PlayerDisplayMode.window,
    );
  }

  Future<void> _toggleSystemPlayerFullscreen() {
    if (_playerDisplayMode == _PlayerDisplayMode.fullscreen) {
      return _setPlayerDisplayMode(_PlayerDisplayMode.window);
    }
    return _setPlayerDisplayMode(
      _PlayerDisplayMode.fullscreen,
    );
  }

  bool get _isTextInputFocused {
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) {
      return false;
    }
    return focusedContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  Future<void> _togglePlay() async {
    if (_activeUrl == null && !_player.state.playing) {
      return;
    }
    await _player.playOrPause();
  }

  Future<void> _seekBy(Duration delta) async {
    if (_activeUrl == null && _player.state.duration == Duration.zero) {
      return;
    }
    final nextPosition = _player.state.position + delta;
    await _player.seek(
      nextPosition.isNegative ? Duration.zero : nextPosition,
    );
  }

  Future<void> _changeVolume(double delta) async {
    final nextVolume = (_player.state.volume + delta).clamp(0, 100).toDouble();
    await _player.setVolume(nextVolume);
  }

  Future<void> _toggleMute() async {
    final volume = _player.state.volume;
    await _player.setVolume(volume > 0 ? 0 : 70);
  }

  bool _handlePlayerShortcut(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.escape &&
        _playerDisplayMode != _PlayerDisplayMode.normal) {
      unawaited(_exitPlayerDisplayMode());
      return true;
    }

    if (_isTextInputFocused) {
      return false;
    }

    switch (key) {
      case LogicalKeyboardKey.space:
        unawaited(_togglePlay());
        return true;
      case LogicalKeyboardKey.keyF:
        unawaited(_toggleSystemPlayerFullscreen());
        return true;
      case LogicalKeyboardKey.keyM:
        unawaited(_toggleMute());
        return true;
      case LogicalKeyboardKey.arrowRight:
        unawaited(_seekBy(const Duration(seconds: 10)));
        return true;
      case LogicalKeyboardKey.arrowLeft:
        unawaited(_seekBy(const Duration(seconds: -10)));
        return true;
      case LogicalKeyboardKey.arrowUp:
        unawaited(_changeVolume(5));
        return true;
      case LogicalKeyboardKey.arrowDown:
        unawaited(_changeVolume(-5));
        return true;
    }

    return false;
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return false;
    }
    return _handlePlayerShortcut(event.logicalKey);
  }

  void _playNextChannel(AuthProvider auth, IptvProvider iptv) {
    final channels = iptv.filteredStreams;
    if (channels.isEmpty) {
      return;
    }

    final currentIndex = channels.indexWhere(
      (channel) => channel.streamId == iptv.selectedStream?.streamId,
    );
    final nextIndex = (currentIndex + 1) % channels.length;
    _activePlaybackIsLive = true;
    _activePlaybackTitle = null;
    _suppressedPlayerUrl = null;
    context.read<IptvProvider>().selectStream(
          stream: channels[nextIndex],
          serverUrl: auth.serverUrl!,
          username: auth.username!,
          password: auth.password!,
        );
  }

  void _openMediaPlayer(String title) {
    setState(() {
      _activePlaybackIsLive = false;
      _activePlaybackTitle = title;
      _suppressedPlayerUrl = null;
      _playerDisplayMode = _PlayerDisplayMode.window;
    });
  }

  void _openMediaItem({
    required MediaCatalogItem item,
    required _LibrarySection section,
    required AuthProvider auth,
    required IptvProvider iptv,
    MediaEpisode? episode,
  }) {
    final sectionKey = _mediaSectionKey(section);
    final savedProgress = iptv.watchProgressFor(
      section: sectionKey,
      item: item,
    );
    iptv.markMediaOpened(section: sectionKey, item: item);
    _activeMediaItem = item;
    _activeMediaSectionKey = sectionKey;
    _pendingResumePosition = savedProgress?.position;
    _lastProgressSavedAt = null;

    if (section == _LibrarySection.movies) {
      iptv.selectMovie(
        movie: item,
        serverUrl: auth.serverUrl!,
        username: auth.username!,
        password: auth.password!,
      );
      _openMediaPlayer(item.name);
      return;
    }

    if (episode != null) {
      iptv.selectSeriesEpisode(
        series: item,
        episode: episode,
        serverUrl: auth.serverUrl!,
        username: auth.username!,
        password: auth.password!,
      );
      _openMediaPlayer(item.name);
      return;
    }

    unawaited(
      iptv
          .selectSeries(
        series: item,
        serverUrl: auth.serverUrl!,
        username: auth.username!,
        password: auth.password!,
      )
          .then((opened) {
        if (opened && mounted) {
          _openMediaPlayer(item.name);
        }
      }),
    );
  }

  void _showMediaDetails({
    required MediaCatalogItem item,
    required _LibrarySection section,
    required AuthProvider auth,
    required IptvProvider iptv,
  }) {
    setState(() {
      _mediaDetailItem = item;
      _mediaDetailSection = section;
    });
    unawaited(
      iptv
          .enrichMediaMetadata(
        item: item,
        isMovie: section == _LibrarySection.movies,
      )
          .then((enriched) {
        if (!mounted ||
            _mediaDetailItem?.id != item.id ||
            _mediaDetailSection != section) {
          return;
        }
        setState(() => _mediaDetailItem = enriched);
      }),
    );
    if (section == _LibrarySection.series) {
      unawaited(
        iptv.loadSeriesEpisodes(
          series: item,
          serverUrl: auth.serverUrl!,
          username: auth.username!,
          password: auth.password!,
        ),
      );
    }
  }

  Future<void> _closeActivePlayer() async {
    _saveMediaProgressFromPlayer(_player.state.position, force: true);
    await windowManager.setFullScreen(false);
    final urlToSuppress = _activeUrl;
    await _player.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _suppressedPlayerUrl = urlToSuppress;
      _activeUrl = null;
      _activeMediaItem = null;
      _activeMediaSectionKey = null;
      _pendingResumePosition = null;
      _activePlaybackIsLive = true;
      _activePlaybackTitle = null;
      _playerDisplayMode = _PlayerDisplayMode.normal;
    });
    _keyboardFocusNode.requestFocus();
  }

  Future<void> _closeMediaPlayer() => _closeActivePlayer();

  Future<void> _openPlayerMedia(String url) async {
    await _player.open(Media(url));
    final resumePosition = _pendingResumePosition;
    _pendingResumePosition = null;
    if (resumePosition != null && resumePosition > const Duration(seconds: 8)) {
      await _player.seek(resumePosition);
    }
  }

  void _saveMediaProgressFromPlayer(
    Duration position, {
    bool force = false,
  }) {
    if (!mounted) {
      return;
    }
    if (_activePlaybackIsLive) {
      return;
    }
    final item = _activeMediaItem;
    final section = _activeMediaSectionKey;
    if (item == null || section == null) {
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastProgressSavedAt != null &&
        now.difference(_lastProgressSavedAt!) < const Duration(seconds: 5)) {
      return;
    }
    _lastProgressSavedAt = now;

    context.read<IptvProvider>().updateMediaProgress(
          section: section,
          item: item,
          position: position,
          duration: _player.state.duration,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final iptv = context.watch<IptvProvider>();
    final visibleCategories = iptv.categories;

    final playerUrl = iptv.playerUrl;
    if (playerUrl != null &&
        playerUrl != _activeUrl &&
        playerUrl != _suppressedPlayerUrl) {
      _activeUrl = playerUrl;
      _playerError = null;
      unawaited(_openPlayerMedia(playerUrl));
    }

    return FScaffold(
      childPad: false,
      child: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, windowConstraints) {
                final compact = windowConstraints.maxWidth < 980 ||
                    windowConstraints.maxHeight < 680;
                const sidebarWidth = 256.0;
                final pagePadding = compact ? 12.0 : 20.0;
                final sectionGap = compact ? 10.0 : 14.0;

                return Column(
                  children: [
                    const _TopContentDivider(),
                    SizedBox(height: sectionGap),
                    Expanded(
                      child: FScaffold(
                        childPad: false,
                        sidebar: _CategorySidebar(
                          width: sidebarWidth,
                          compact: compact,
                          activeSection: _librarySection,
                          channelView: iptv.channelView,
                          favoritesCount: iptv.favoritesCount,
                          recentCount: iptv.recentCount,
                          onLiveSelected: () {
                            final provider = context.read<IptvProvider>();
                            if (!_activePlaybackIsLive) {
                              unawaited(_closeMediaPlayer());
                            }
                            setState(
                              () => _librarySection = _LibrarySection.live,
                            );
                            final category = provider.selectedCategory ??
                                (provider.categories.isEmpty
                                    ? null
                                    : provider.categories.first);
                            if (category != null) {
                              provider.selectCategory(category);
                            }
                          },
                          onMoviesSelected: () {
                            unawaited(
                              context.read<IptvProvider>().ensureMoviesLoaded(
                                    serverUrl: auth.serverUrl!,
                                    username: auth.username!,
                                    password: auth.password!,
                                  ),
                            );
                            setState(
                              () => _librarySection = _LibrarySection.movies,
                            );
                          },
                          onSeriesSelected: () {
                            unawaited(
                              context.read<IptvProvider>().ensureSeriesLoaded(
                                    serverUrl: auth.serverUrl!,
                                    username: auth.username!,
                                    password: auth.password!,
                                  ),
                            );
                            setState(
                              () => _librarySection = _LibrarySection.series,
                            );
                          },
                          onFavoritesSelected: () {
                            if (!_activePlaybackIsLive) {
                              unawaited(_closeMediaPlayer());
                            }
                            setState(
                              () => _librarySection = _LibrarySection.live,
                            );
                            context.read<IptvProvider>().selectFavorites();
                          },
                          onRecentSelected: () {
                            if (!_activePlaybackIsLive) {
                              unawaited(_closeMediaPlayer());
                            }
                            setState(
                              () => _librarySection = _LibrarySection.live,
                            );
                            context.read<IptvProvider>().selectRecent();
                          },
                          onLogout: () async {
                            await _player.stop();
                            if (!context.mounted) {
                              return;
                            }
                            context.read<IptvProvider>().reset();
                            await context.read<AuthProvider>().logout();
                          },
                        ),
                        child: SafeArea(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              pagePadding,
                              0,
                              pagePadding,
                              pagePadding,
                            ),
                            child: Column(
                              children: [
                                if (_librarySection ==
                                    _LibrarySection.live) ...[
                                  Expanded(
                                    child: _LiveTvCatalogPage(
                                      compact: compact,
                                      isLoading: iptv.isLoading,
                                      errorMessage: iptv.errorMessage,
                                      categories: visibleCategories,
                                      channels: iptv.filteredStreams,
                                      channelView: iptv.channelView,
                                      selectedCategory: iptv.selectedCategory,
                                      selectedStream: iptv.selectedStream,
                                      favoriteStreamIds: iptv.favoriteStreamIds,
                                      epgForStream: iptv.epgForStream,
                                      isEpgLoading: iptv.isEpgLoading,
                                      onSearchPressed: () {
                                        setState(() => _searchOpen = true);
                                      },
                                      onCategorySelected: context
                                          .read<IptvProvider>()
                                          .selectCategory,
                                      onChannelSelected: (stream) {
                                        _activePlaybackIsLive = true;
                                        _activePlaybackTitle = null;
                                        _suppressedPlayerUrl = null;
                                        context
                                            .read<IptvProvider>()
                                            .selectStream(
                                              stream: stream,
                                              serverUrl: auth.serverUrl!,
                                              username: auth.username!,
                                              password: auth.password!,
                                            );
                                        setState(
                                          () => _playerDisplayMode =
                                              _PlayerDisplayMode.window,
                                        );
                                      },
                                      onFavoriteToggled: context
                                          .read<IptvProvider>()
                                          .toggleFavorite,
                                      onEpgRequested: (stream) {
                                        context
                                            .read<IptvProvider>()
                                            .loadEpgForStream(
                                              stream: stream,
                                              serverUrl: auth.serverUrl!,
                                              username: auth.username!,
                                              password: auth.password!,
                                            );
                                      },
                                    ),
                                  ),
                                ] else
                                  Expanded(
                                    child: _MediaLibraryPage(
                                      section: _librarySection,
                                      loading: _librarySection ==
                                              _LibrarySection.movies
                                          ? iptv.isMoviesLoading
                                          : iptv.isSeriesLoading,
                                      errorMessage: _librarySection ==
                                              _LibrarySection.movies
                                          ? iptv.movieErrorMessage
                                          : iptv.seriesErrorMessage,
                                      categories: _librarySection ==
                                              _LibrarySection.movies
                                          ? iptv.movieCategories
                                          : iptv.seriesCategories,
                                      items: _librarySection ==
                                              _LibrarySection.movies
                                          ? iptv.movies
                                          : iptv.series,
                                      watchHistory: iptv.watchHistoryFor(
                                        _mediaSectionKey(_librarySection),
                                      ),
                                      onSearchPressed: () {
                                        setState(
                                          () => _mediaSearchSection =
                                              _librarySection,
                                        );
                                      },
                                      onItemPressed: (item) {
                                        _showMediaDetails(
                                          item: item,
                                          section: _librarySection,
                                          auth: auth,
                                          iptv: context.read<IptvProvider>(),
                                        );
                                      },
                                      onContinuePressed: (item) {
                                        _openMediaItem(
                                          item: item,
                                          section: _librarySection,
                                          auth: auth,
                                          iptv: context.read<IptvProvider>(),
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            if (_playerDisplayMode != _PlayerDisplayMode.normal)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black,
                  child: _PlayerPanel(
                    controller: _videoController,
                    player: _player,
                    hasStream: playerUrl != null,
                    error: _playerError,
                    isLive: _activePlaybackIsLive,
                    title: _activePlaybackTitle,
                    displayMode: _playerDisplayMode,
                    onWindowMode: _toggleWindowPlayerMode,
                    onFullscreen: _toggleSystemPlayerFullscreen,
                    onExitDisplayMode: _exitPlayerDisplayMode,
                    onNext: () => _playNextChannel(auth, iptv),
                  ),
                ),
              ),
            if (_searchOpen)
              Positioned.fill(
                child: _SearchOverlay(
                  categories: iptv.categories,
                  streams: iptv.streams,
                  favoriteStreamIds: iptv.favoriteStreamIds,
                  onDismissed: () {
                    setState(() => _searchOpen = false);
                    _keyboardFocusNode.requestFocus();
                  },
                  onFavoriteToggled:
                      context.read<IptvProvider>().toggleFavorite,
                  onCategorySelected: (category) {
                    context.read<IptvProvider>()
                      ..setSearchQuery('')
                      ..setSearchAllChannels(false)
                      ..selectCategory(category);
                    setState(() => _searchOpen = false);
                    _keyboardFocusNode.requestFocus();
                  },
                  onStreamSelected: (stream) {
                    _activePlaybackIsLive = true;
                    _activePlaybackTitle = null;
                    _suppressedPlayerUrl = null;
                    context.read<IptvProvider>()
                      ..setSearchQuery('')
                      ..setSearchAllChannels(false)
                      ..selectStream(
                        stream: stream,
                        serverUrl: auth.serverUrl!,
                        username: auth.username!,
                        password: auth.password!,
                      );
                    setState(() {
                      _searchOpen = false;
                      _playerDisplayMode = _PlayerDisplayMode.window;
                    });
                    _keyboardFocusNode.requestFocus();
                  },
                ),
              ),
            if (_mediaSearchSection != null)
              Positioned.fill(
                child: _MediaSearchOverlay(
                  section: _mediaSearchSection!,
                  categories: _mediaSearchSection == _LibrarySection.movies
                      ? iptv.movieCategories
                      : iptv.seriesCategories,
                  items: _mediaSearchSection == _LibrarySection.movies
                      ? iptv.movies
                      : iptv.series,
                  onDismissed: () {
                    setState(() => _mediaSearchSection = null);
                    _keyboardFocusNode.requestFocus();
                  },
                  onItemSelected: (item) {
                    final section = _mediaSearchSection!;
                    setState(() => _mediaSearchSection = null);
                    _showMediaDetails(
                      item: item,
                      section: section,
                      auth: auth,
                      iptv: context.read<IptvProvider>(),
                    );
                    _keyboardFocusNode.requestFocus();
                  },
                ),
              ),
            if (_mediaDetailItem != null && _mediaDetailSection != null)
              Positioned.fill(
                child: Builder(
                  builder: (context) {
                    final detailItem = iptv.latestMediaItem(
                          id: _mediaDetailItem!.id,
                          isMovie:
                              _mediaDetailSection == _LibrarySection.movies,
                        ) ??
                        _mediaDetailItem!;
                    return _MediaDetailOverlay(
                      item: detailItem,
                      section: _mediaDetailSection!,
                      categories: _mediaDetailSection == _LibrarySection.movies
                          ? iptv.movieCategories
                          : iptv.seriesCategories,
                      progress: iptv.watchProgressFor(
                        section: _mediaSectionKey(_mediaDetailSection!),
                        item: detailItem,
                      ),
                      episodes: _mediaDetailSection == _LibrarySection.series
                          ? iptv.seriesEpisodesFor(detailItem.id)
                          : const <MediaEpisode>[],
                      loadingEpisodes:
                          _mediaDetailSection == _LibrarySection.series
                              ? iptv.isLoadingSeriesEpisodes(detailItem.id)
                              : false,
                      onDismissed: () {
                        setState(() {
                          _mediaDetailItem = null;
                          _mediaDetailSection = null;
                        });
                        _keyboardFocusNode.requestFocus();
                      },
                      onPlayPressed: () {
                        final section = _mediaDetailSection!;
                        setState(() {
                          _mediaDetailItem = null;
                          _mediaDetailSection = null;
                        });
                        _openMediaItem(
                          item: detailItem,
                          section: section,
                          auth: auth,
                          iptv: context.read<IptvProvider>(),
                        );
                        _keyboardFocusNode.requestFocus();
                      },
                      onEpisodePressed: (episode) {
                        final section = _mediaDetailSection!;
                        setState(() {
                          _mediaDetailItem = null;
                          _mediaDetailSection = null;
                        });
                        _openMediaItem(
                          item: detailItem,
                          section: section,
                          auth: auth,
                          iptv: context.read<IptvProvider>(),
                          episode: episode,
                        );
                        _keyboardFocusNode.requestFocus();
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopContentDivider extends StatelessWidget {
  const _TopContentDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
      ),
    );
  }
}

class _CategorySidebar extends StatelessWidget {
  const _CategorySidebar({
    required this.width,
    required this.compact,
    required this.activeSection,
    required this.channelView,
    required this.favoritesCount,
    required this.recentCount,
    required this.onLiveSelected,
    required this.onMoviesSelected,
    required this.onSeriesSelected,
    required this.onFavoritesSelected,
    required this.onRecentSelected,
    required this.onLogout,
  });

  final double width;
  final bool compact;
  final _LibrarySection activeSection;
  final ChannelView channelView;
  final int favoritesCount;
  final int recentCount;
  final VoidCallback onLiveSelected;
  final VoidCallback onMoviesSelected;
  final VoidCallback onSeriesSelected;
  final VoidCallback onFavoritesSelected;
  final VoidCallback onRecentSelected;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final liveSelected = activeSection == _LibrarySection.live &&
        channelView == ChannelView.category;

    return SizedBox(
      width: width,
      child: FSidebar(
        footer: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FCard.raw(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  FAvatar.raw(
                    size: 34,
                    child: Icon(
                      FLucideIcons.userRound,
                      size: 18,
                      color: context.theme.colors.mutedForeground,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mateo',
                          overflow: TextOverflow.ellipsis,
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.colors.foreground,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Xtream nalog',
                          overflow: TextOverflow.ellipsis,
                          style: context.theme.typography.xs.copyWith(
                            color: context.theme.colors.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: 'Logout',
                    child: FButton.icon(
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      onPress: onLogout,
                      child: const Icon(FLucideIcons.logOut, size: 17),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        children: [
          FSidebarGroup(
            label: const Text('Navigacija'),
            children: [
              FSidebarItem(
                icon: const Icon(FLucideIcons.monitorPlay),
                label: const Text('Live TV'),
                selected: liveSelected,
                onPress: onLiveSelected,
              ),
              FSidebarItem(
                icon: const Icon(FLucideIcons.film),
                label: const Text('Filmovi'),
                selected: activeSection == _LibrarySection.movies,
                onPress: onMoviesSelected,
              ),
              FSidebarItem(
                icon: const Icon(FLucideIcons.clapperboard),
                label: const Text('Serije'),
                selected: activeSection == _LibrarySection.series,
                onPress: onSeriesSelected,
              ),
            ],
          ),
          FSidebarGroup(
            label: const Text('Biblioteka'),
            children: [
              FSidebarItem(
                icon: const Icon(FLucideIcons.star),
                label: Text('Favourites ($favoritesCount)'),
                selected: activeSection == _LibrarySection.live &&
                    channelView == ChannelView.favorites,
                onPress: onFavoritesSelected,
              ),
              FSidebarItem(
                icon: const Icon(FLucideIcons.history),
                label: Text('Recently viewed ($recentCount)'),
                selected: activeSection == _LibrarySection.live &&
                    channelView == ChannelView.recent,
                onPress: onRecentSelected,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchBarButton extends StatelessWidget {
  const _SearchBarButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: FTappable(
        onPress: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF111417),
            borderRadius: context.theme.style.borderRadius.md,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Row(
              children: [
                Icon(
                  FLucideIcons.search,
                  size: 17,
                  color: context.theme.colors.mutedForeground,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.typography.sm.copyWith(
                      color: context.theme.colors.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  FLucideIcons.command,
                  size: 15,
                  color: context.theme.colors.mutedForeground,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaLibraryPage extends StatefulWidget {
  const _MediaLibraryPage({
    required this.section,
    required this.loading,
    required this.errorMessage,
    required this.categories,
    required this.items,
    required this.watchHistory,
    required this.onSearchPressed,
    required this.onItemPressed,
    required this.onContinuePressed,
  });

  final _LibrarySection section;
  final bool loading;
  final String? errorMessage;
  final List<LiveCategory> categories;
  final List<MediaCatalogItem> items;
  final List<WatchProgress> watchHistory;
  final VoidCallback onSearchPressed;
  final ValueChanged<MediaCatalogItem> onItemPressed;
  final ValueChanged<MediaCatalogItem> onContinuePressed;

  @override
  State<_MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<_MediaLibraryPage> {
  _MediaRailData? _viewAllRail;
  bool _viewAllContinue = false;

  @override
  Widget build(BuildContext context) {
    final isMovies = widget.section == _LibrarySection.movies;
    final title = isMovies ? 'Filmovi' : 'Serije';
    final icon = isMovies ? FLucideIcons.film : FLucideIcons.clapperboard;

    return Stack(
      children: [
        FCard.raw(
          style: _darkCardStyle(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    FAvatar.raw(
                      size: 34,
                      child: Icon(
                        icon,
                        size: 18,
                        color: context.theme.colors.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: context.theme.typography.xl.copyWith(
                          color: context.theme.colors.foreground,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SearchBarButton(
                  label:
                      isMovies ? 'Pretrazi filmove...' : 'Pretrazi serije...',
                  onPressed: widget.onSearchPressed,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _MediaLibraryBody(
                    loading: widget.loading,
                    errorMessage: widget.errorMessage,
                    categories: widget.categories,
                    items: widget.items,
                    watchHistory: widget.watchHistory,
                    isMovies: isMovies,
                    onItemPressed: widget.onItemPressed,
                    onContinuePressed: widget.onContinuePressed,
                    onViewAllPressed: (rail) {
                      setState(() => _viewAllRail = rail);
                    },
                    onViewAllContinuePressed: () {
                      setState(() => _viewAllContinue = true);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_viewAllRail != null)
          Positioned.fill(
            child: _MediaViewAllOverlay(
              rail: _viewAllRail!,
              onDismissed: () => setState(() => _viewAllRail = null),
              onItemPressed: (item) {
                setState(() => _viewAllRail = null);
                widget.onItemPressed(item);
              },
            ),
          ),
        if (_viewAllContinue)
          Positioned.fill(
            child: _MediaViewAllOverlay(
              rail: _MediaRailData(
                title: 'Continue watching',
                items: widget.watchHistory
                    .map((progress) => progress.item)
                    .toList(growable: false),
                wide: true,
              ),
              onDismissed: () => setState(() => _viewAllContinue = false),
              onItemPressed: (item) {
                setState(() => _viewAllContinue = false);
                widget.onContinuePressed(item);
              },
            ),
          ),
      ],
    );
  }
}

class _MediaDetailOverlay extends StatefulWidget {
  const _MediaDetailOverlay({
    required this.item,
    required this.section,
    required this.categories,
    required this.progress,
    required this.episodes,
    required this.loadingEpisodes,
    required this.onDismissed,
    required this.onPlayPressed,
    required this.onEpisodePressed,
  });

  final MediaCatalogItem item;
  final _LibrarySection section;
  final List<LiveCategory> categories;
  final WatchProgress? progress;
  final List<MediaEpisode> episodes;
  final bool loadingEpisodes;
  final VoidCallback onDismissed;
  final VoidCallback onPlayPressed;
  final ValueChanged<MediaEpisode> onEpisodePressed;

  @override
  State<_MediaDetailOverlay> createState() => _MediaDetailOverlayState();
}

class _MediaDetailOverlayState extends State<_MediaDetailOverlay> {
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;
  bool _detailsSelected = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    final nextOffset = _scrollController.offset.clamp(0.0, 140.0);
    if ((nextOffset - _scrollOffset).abs() < 2) {
      return;
    }
    setState(() => _scrollOffset = nextOffset);
  }

  @override
  Widget build(BuildContext context) {
    final isSeries = widget.section == _LibrarySection.series;
    final blurAmount = (_scrollOffset / 140 * 8).clamp(0.0, 8.0);
    final categoryName = widget.categories
            .where((category) => category.categoryId == widget.item.categoryId)
            .firstOrNull
            ?.categoryName ??
        (isSeries ? 'Serija' : 'Film');
    final hasProgress = widget.progress != null &&
        widget.progress!.position > const Duration(seconds: 8);
    final playLabel = hasProgress
        ? 'Continue ${_formatPlaybackTime(widget.progress!.position)}'
        : isSeries
            ? 'Play Season 1: Episode 1'
            : 'Play';
    final metadata = _mediaMetadata(widget.item, categoryName);

    return Stack(
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.62),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080, maxHeight: 720),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: blurAmount,
                          sigmaY: blurAmount,
                        ),
                        child: _MediaDetailBackdrop(item: widget.item),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Colors.black.withValues(alpha: 0.90),
                              Colors.black.withValues(alpha: 0.74),
                              Colors.black.withValues(alpha: 0.36),
                            ],
                            stops: const [0.0, 0.48, 1.0],
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.10),
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 18,
                      right: 18,
                      child: FButton.icon(
                        variant: FButtonVariant.ghost,
                        onPress: widget.onDismissed,
                        child: const Icon(FLucideIcons.x, size: 22),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 86, 28, 24),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 132),
                            SizedBox(
                              width: 390,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.item.name,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 42,
                                      height: 0.98,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  if (metadata.isNotEmpty) ...[
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        for (final value in metadata)
                                          FBadge(
                                            variant: FBadgeVariant.secondary,
                                            child: Text(value),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 18),
                                  ],
                                  if (_mediaDetailDescription(
                                    widget.item,
                                    isSeries,
                                  ).isNotEmpty) ...[
                                    Text(
                                      _mediaDetailDescription(
                                        widget.item,
                                        isSeries,
                                      ),
                                      maxLines: 8,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          context.theme.typography.sm.copyWith(
                                        color: Colors.white
                                            .withValues(alpha: 0.74),
                                        height: 1.35,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 22),
                                  ],
                                  SizedBox(
                                    width: 330,
                                    child: FButton(
                                      onPress: widget.onPlayPressed,
                                      prefix: const Icon(
                                        FLucideIcons.play,
                                        size: 16,
                                      ),
                                      child: Text(playLabel),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 26),
                            Divider(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                _DetailTabButton(
                                  selected: !_detailsSelected,
                                  label: isSeries ? 'Episodes' : 'Overview',
                                  onPressed: () {
                                    setState(() => _detailsSelected = false);
                                  },
                                ),
                                const SizedBox(width: 10),
                                _DetailTabButton(
                                  selected: _detailsSelected,
                                  label: 'Details',
                                  onPressed: () {
                                    setState(() => _detailsSelected = true);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (_detailsSelected)
                              _MediaDetailsPanel(
                                item: widget.item,
                                categoryName: categoryName,
                              )
                            else if (isSeries)
                              _SeriesEpisodesPanel(
                                fallbackItem: widget.item,
                                episodes: widget.episodes,
                                loading: widget.loadingEpisodes,
                                onEpisodePressed: widget.onEpisodePressed,
                              )
                            else
                              _MovieDetailPreview(
                                item: widget.item,
                                categoryName: categoryName,
                                progress: widget.progress,
                              ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

List<String> _mediaMetadata(MediaCatalogItem item, String categoryName) {
  return [
    if (item.rating != null) item.rating!,
    if (_yearFromDate(item.releaseDate) != null)
      _yearFromDate(item.releaseDate)!,
    if (item.genre != null) item.genre!,
    if (item.genre == null) categoryName,
  ];
}

String? _yearFromDate(String? value) {
  if (value == null) {
    return null;
  }
  final match = RegExp(r'\b(19|20)\d{2}\b').firstMatch(value);
  return match?.group(0);
}

class _DetailTabButton extends StatelessWidget {
  const _DetailTabButton({
    required this.selected,
    required this.label,
    required this.onPressed,
  });

  final bool selected;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FButton(
      variant: selected ? FButtonVariant.secondary : FButtonVariant.ghost,
      size: FButtonSizeVariant.sm,
      onPress: onPressed,
      child: Text(label),
    );
  }
}

class _MediaDetailsPanel extends StatelessWidget {
  const _MediaDetailsPanel({
    required this.item,
    required this.categoryName,
  });

  final MediaCatalogItem item;
  final String categoryName;

  @override
  Widget build(BuildContext context) {
    final rows = [
      if (item.rating != null) ('Ocjena', item.rating!),
      if (_yearFromDate(item.releaseDate) != null)
        ('Godina', _yearFromDate(item.releaseDate)!),
      ('Kategorija', item.genre ?? categoryName),
      if (item.director != null) ('Režija', item.director!),
      if (item.cast != null) ('Glumci', item.cast!),
      if (item.metadataSource == 'tmdb') ('Izvor', 'TMDb'),
    ];
    final description = _mediaDetailDescription(
      item,
      item.containerExtension == null,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: FCard.raw(
        style: _darkCardStyle(context, borderless: true),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final row in rows) ...[
                _DetailInfoRow(label: row.$1, value: row.$2),
                const SizedBox(height: 10),
              ],
              if (description.isNotEmpty) ...[
                Text(
                  'Opis',
                  style: context.theme.typography.xs.copyWith(
                    color: context.theme.colors.mutedForeground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  description,
                  style: context.theme.typography.sm.copyWith(
                    color: context.theme.colors.foreground,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailInfoRow extends StatelessWidget {
  const _DetailInfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: context.theme.typography.xs.copyWith(
              color: context.theme.colors.mutedForeground,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: context.theme.typography.sm.copyWith(
              color: context.theme.colors.foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaDetailBackdrop extends StatelessWidget {
  const _MediaDetailBackdrop({required this.item});

  final MediaCatalogItem item;

  @override
  Widget build(BuildContext context) {
    final imageUrl = item.backdropUrl ?? item.posterUrl;
    if (imageUrl == null) {
      return _PosterFallback(item: item, wide: true);
    }
    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      placeholder: (_, __) => _PosterFallback(item: item, wide: true),
      errorWidget: (_, __, ___) => _PosterFallback(item: item, wide: true),
    );
  }
}

class _SeriesEpisodesPanel extends StatefulWidget {
  const _SeriesEpisodesPanel({
    required this.fallbackItem,
    required this.episodes,
    required this.loading,
    required this.onEpisodePressed,
  });

  final MediaCatalogItem fallbackItem;
  final List<MediaEpisode> episodes;
  final bool loading;
  final ValueChanged<MediaEpisode> onEpisodePressed;

  @override
  State<_SeriesEpisodesPanel> createState() => _SeriesEpisodesPanelState();
}

class _SeriesEpisodesPanelState extends State<_SeriesEpisodesPanel> {
  int? _selectedSeason;

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.episodes.isEmpty) {
      return const Center(child: FCircularProgress());
    }

    if (widget.episodes.isEmpty) {
      return Text(
        'Nema epizoda za prikaz.',
        style: context.theme.typography.sm.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      );
    }

    final seasons = widget.episodes
        .map((episode) => episode.seasonNumber)
        .toSet()
        .toList(growable: false)
      ..sort();
    final selectedSeason = _selectedSeason ?? seasons.first;
    final episodes = widget.episodes
        .where((episode) => episode.seasonNumber == selectedSeason)
        .toList(growable: false)
      ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

    return Column(
      children: [
        Row(
          children: [
            Text(
              'Episodes',
              style: context.theme.typography.sm.copyWith(
                color: context.theme.colors.foreground,
                fontWeight: FontWeight.w900,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 170,
              child: FSelect<int>(
                items: {
                  for (final season in seasons) 'Season $season': season,
                },
                control: FSelectControl.managed(
                  initial: selectedSeason,
                  onChange: (value) {
                    if (value != null) {
                      setState(() => _selectedSeason = value);
                    }
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final episode in episodes) ...[
          Align(
            alignment: Alignment.center,
            child: _SeriesEpisodeTile(
              fallbackItem: widget.fallbackItem,
              episode: episode,
              onPressed: () => widget.onEpisodePressed(episode),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _SeriesEpisodeTile extends StatefulWidget {
  const _SeriesEpisodeTile({
    required this.fallbackItem,
    required this.episode,
    required this.onPressed,
  });

  final MediaCatalogItem fallbackItem;
  final MediaEpisode episode;
  final VoidCallback onPressed;

  @override
  State<_SeriesEpisodeTile> createState() => _SeriesEpisodeTileState();
}

class _SeriesEpisodeTileState extends State<_SeriesEpisodeTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final episodeFacts = [
      if (widget.episode.rating != null) widget.episode.rating!,
      if (_yearFromDate(widget.episode.releaseDate) != null)
        _yearFromDate(widget.episode.releaseDate)!,
      if (widget.episode.director != null)
        'Režija: ${widget.episode.director!}',
      if (_hovered && widget.episode.cast != null)
        'Glumci: ${widget.episode.cast!}',
    ];

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        width: _hovered ? 860 : 760,
        child: FCard.raw(
          style: _darkCardStyle(
            context,
            hovered: _hovered,
            borderless: true,
          ),
          child: FTappable(
            onPress: widget.onPressed,
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.all(_hovered ? 14 : 8),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    width: _hovered ? 154 : 132,
                    height: _hovered ? 86 : 74,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: widget.episode.imageUrl == null
                          ? _MediaPoster(item: widget.fallbackItem, wide: true)
                          : CachedNetworkImage(
                              imageUrl: widget.episode.imageUrl!,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => _MediaPoster(
                                item: widget.fallbackItem,
                                wide: true,
                              ),
                              errorWidget: (_, __, ___) => _MediaPoster(
                                item: widget.fallbackItem,
                                wide: true,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'S${widget.episode.seasonNumber.toString().padLeft(2, '0')}E${widget.episode.episodeNumber.toString().padLeft(2, '0')}',
                          style: context.theme.typography.xs.copyWith(
                            color: context.theme.colors.mutedForeground,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          widget.episode.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.colors.foreground,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        if (episodeFacts.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            episodeFacts.join('  •  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.theme.typography.xs.copyWith(
                              color: context.theme.colors.mutedForeground,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          widget.episode.plot ??
                              'Opis epizode nije dostupan u listi.',
                          maxLines: _hovered ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.theme.typography.xs.copyWith(
                            color: context.theme.colors.mutedForeground,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    FLucideIcons.play,
                    size: 18,
                    color: _hovered
                        ? context.theme.colors.primary
                        : context.theme.colors.mutedForeground,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MovieDetailPreview extends StatelessWidget {
  const _MovieDetailPreview({
    required this.item,
    required this.categoryName,
    required this.progress,
  });

  final MediaCatalogItem item;
  final String categoryName;
  final WatchProgress? progress;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 82,
          height: 116,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: _MediaPoster(item: item, wide: false),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.colors.foreground,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                categoryName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.xs.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: progress!.progress,
                  minHeight: 4,
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    context.theme.colors.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String _mediaDetailDescription(MediaCatalogItem item, bool isSeries) {
  final plot = item.plot;
  if (plot != null && plot.trim().isNotEmpty) {
    return plot.trim();
  }
  if (isSeries) {
    return 'Odaberi seriju da otvoriš prvu dostupnu epizodu. Detalje i sezone možemo kasnije proširiti ako ih tvoja lista šalje kroz Xtream API.';
  }
  return 'Film iz tvoje IPTV liste. Pritisni Play za pokretanje ili Continue ako je već gledan.';
}

class _MediaLibraryBody extends StatelessWidget {
  const _MediaLibraryBody({
    required this.loading,
    required this.errorMessage,
    required this.categories,
    required this.items,
    required this.watchHistory,
    required this.isMovies,
    required this.onItemPressed,
    required this.onContinuePressed,
    required this.onViewAllPressed,
    required this.onViewAllContinuePressed,
  });

  final bool loading;
  final String? errorMessage;
  final List<LiveCategory> categories;
  final List<MediaCatalogItem> items;
  final List<WatchProgress> watchHistory;
  final bool isMovies;
  final ValueChanged<MediaCatalogItem> onItemPressed;
  final ValueChanged<MediaCatalogItem> onContinuePressed;
  final ValueChanged<_MediaRailData> onViewAllPressed;
  final VoidCallback onViewAllContinuePressed;

  @override
  Widget build(BuildContext context) {
    if (loading && items.isEmpty) {
      return const Center(child: FCircularProgress());
    }
    if (errorMessage != null && items.isEmpty) {
      return Center(child: Text(errorMessage!));
    }
    if (items.isEmpty) {
      return Center(
        child:
            Text(isMovies ? 'Nema filmova za prikaz' : 'Nema serija za prikaz'),
      );
    }

    final categoryNames = {
      for (final category in categories)
        category.categoryId: category.categoryName,
    };
    final rails = _buildMediaRails(categories, items);
    final hasContinue = watchHistory.isNotEmpty;
    return ListView.separated(
      itemCount: rails.length + (hasContinue ? 1 : 0),
      separatorBuilder: (context, index) => const SizedBox(height: 18),
      itemBuilder: (context, index) {
        if (hasContinue && index == 0) {
          return _ContinueWatchingRail(
            items: watchHistory,
            onItemPressed: onContinuePressed,
            onViewAllPressed: onViewAllContinuePressed,
          );
        }

        final rail = rails[index - (hasContinue ? 1 : 0)];
        return _MediaRail(
          rail: rail,
          categoryNames: categoryNames,
          onItemPressed: onItemPressed,
          onViewAllPressed: () => onViewAllPressed(rail),
        );
      },
    );
  }
}

class _ContinueWatchingRail extends StatefulWidget {
  const _ContinueWatchingRail({
    required this.items,
    required this.onItemPressed,
    required this.onViewAllPressed,
  });

  final List<WatchProgress> items;
  final ValueChanged<MediaCatalogItem> onItemPressed;
  final VoidCallback onViewAllPressed;

  @override
  State<_ContinueWatchingRail> createState() => _ContinueWatchingRailState();
}

class _ContinueWatchingRailState extends State<_ContinueWatchingRail> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    if (!_scrollController.hasClients) {
      return;
    }
    final nextOffset = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      nextOffset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 204,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Continue watching',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.typography.sm.copyWith(
                    color: context.theme.colors.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${widget.items.length}',
                style: context.theme.typography.xs.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
              const SizedBox(width: 8),
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: widget.onViewAllPressed,
                child: const Text('view all'),
              ),
              const SizedBox(width: 4),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: () => _scrollBy(-460),
                child: const Icon(FLucideIcons.chevronLeft, size: 16),
              ),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: () => _scrollBy(460),
                child: const Icon(FLucideIcons.chevronRight, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ClipRect(
              child: ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                scrollDirection: Axis.horizontal,
                itemCount: widget.items.length,
                separatorBuilder: (context, index) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final progress = widget.items[index];
                  return _ContinueWatchingTile(
                    progress: progress,
                    onPressed: () => widget.onItemPressed(progress.item),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueWatchingTile extends StatefulWidget {
  const _ContinueWatchingTile({
    required this.progress,
    required this.onPressed,
  });

  final WatchProgress progress;
  final VoidCallback onPressed;

  @override
  State<_ContinueWatchingTile> createState() => _ContinueWatchingTileState();
}

class _ContinueWatchingTileState extends State<_ContinueWatchingTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final width = _hovered ? 260.0 : 222.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        width: width,
        child: AnimatedScale(
          scale: _hovered ? 1.04 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: FCard.raw(
            style: _darkCardStyle(
              context,
              hovered: _hovered,
              borderless: true,
            ),
            child: FTappable(
              onPress: widget.onPressed,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _MediaPoster(
                              item: widget.progress.item,
                              wide: true,
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: widget.progress.progress,
                                minHeight: 4,
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.2),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  context.theme.colors.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.progress.item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.xs.copyWith(
                        color: context.theme.colors.foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _formatContinueProgress(widget.progress),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.xs.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatContinueProgress(WatchProgress progress) {
  final position = _formatPlaybackTime(progress.position);
  if (progress.duration.inSeconds <= 0) {
    return position;
  }
  return '$position / ${_formatPlaybackTime(progress.duration)}';
}

List<_MediaRailData> _buildMediaRails(
  List<LiveCategory> categories,
  List<MediaCatalogItem> items,
) {
  final rails = <_MediaRailData>[
    _MediaRailData(
      title: 'Recently added',
      items: items,
      wide: true,
    ),
  ];

  for (final category in categories.take(12)) {
    final categoryItems = items
        .where((item) => item.categoryId == category.categoryId)
        .toList(growable: false);
    if (categoryItems.isNotEmpty) {
      rails.add(
        _MediaRailData(
          title: category.categoryName,
          items: categoryItems,
        ),
      );
    }
  }

  return rails;
}

class _MediaRail extends StatelessWidget {
  const _MediaRail({
    required this.rail,
    required this.categoryNames,
    required this.onItemPressed,
    required this.onViewAllPressed,
  });

  final _MediaRailData rail;
  final Map<String, String> categoryNames;
  final ValueChanged<MediaCatalogItem> onItemPressed;
  final VoidCallback onViewAllPressed;

  @override
  Widget build(BuildContext context) {
    return _ScrollableMediaRail(
      rail: rail,
      categoryNames: categoryNames,
      onItemPressed: onItemPressed,
      onViewAllPressed: onViewAllPressed,
    );
  }
}

class _ScrollableMediaRail extends StatefulWidget {
  const _ScrollableMediaRail({
    required this.rail,
    required this.categoryNames,
    required this.onItemPressed,
    required this.onViewAllPressed,
  });

  final _MediaRailData rail;
  final Map<String, String> categoryNames;
  final ValueChanged<MediaCatalogItem> onItemPressed;
  final VoidCallback onViewAllPressed;

  @override
  State<_ScrollableMediaRail> createState() => _ScrollableMediaRailState();
}

class _ScrollableMediaRailState extends State<_ScrollableMediaRail> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    if (!_scrollController.hasClients) {
      return;
    }
    final nextOffset = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      nextOffset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rail = widget.rail;
    return SizedBox(
      height: rail.wide ? 194 : 238,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  rail.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.typography.sm.copyWith(
                    color: context.theme.colors.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${rail.items.length}',
                style: context.theme.typography.xs.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
              const SizedBox(width: 8),
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: widget.onViewAllPressed,
                child: const Text('view all'),
              ),
              const SizedBox(width: 4),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: () => _scrollBy(rail.wide ? -460 : -300),
                child: const Icon(FLucideIcons.chevronLeft, size: 16),
              ),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: () => _scrollBy(rail.wide ? 460 : 300),
                child: const Icon(FLucideIcons.chevronRight, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              controller: _scrollController,
              clipBehavior: Clip.none,
              scrollDirection: Axis.horizontal,
              itemCount: rail.items.length,
              padding: const EdgeInsets.symmetric(vertical: 8),
              separatorBuilder: (context, index) => const SizedBox(width: 14),
              itemBuilder: (context, index) => _MediaTile(
                item: rail.items[index],
                wide: rail.wide,
                subtitle: widget.categoryNames[rail.items[index].categoryId] ??
                    rail.title,
                onPressed: () => widget.onItemPressed(rail.items[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaTile extends StatefulWidget {
  const _MediaTile({
    required this.item,
    required this.wide,
    required this.subtitle,
    required this.onPressed,
  });

  final MediaCatalogItem item;
  final bool wide;
  final String subtitle;
  final VoidCallback onPressed;

  @override
  State<_MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<_MediaTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final baseWidth = widget.wide ? 222.0 : 128.0;
    final width = _hovered ? baseWidth * 1.25 : baseWidth;
    final posterFlex = widget.wide ? 5 : 7;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        width: width,
        child: AnimatedScale(
          scale: _hovered ? 1.1 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: FCard.raw(
            style: _darkCardStyle(
              context,
              hovered: _hovered,
              borderless: true,
            ),
            child: FTappable(
              onPress: widget.onPressed,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: posterFlex,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _MediaPoster(item: widget.item, wide: widget.wide),
                            if (widget.item.rating != null)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: FBadge(
                                  child: Text(widget.item.rating!),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.item.name,
                      maxLines: widget.wide ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.xs.copyWith(
                        color: context.theme.colors.foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.xs.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaViewAllOverlay extends StatelessWidget {
  const _MediaViewAllOverlay({
    required this.rail,
    required this.onDismissed,
    required this.onItemPressed,
  });

  final _MediaRailData rail;
  final VoidCallback onDismissed;
  final ValueChanged<MediaCatalogItem> onItemPressed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismissed,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.52),
              ),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960, maxHeight: 680),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: FCard.raw(
                style: _darkCardStyle(context),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              rail.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.theme.typography.lg.copyWith(
                                color: context.theme.colors.foreground,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Text(
                            '${rail.items.length}',
                            style: context.theme.typography.xs.copyWith(
                              color: context.theme.colors.mutedForeground,
                            ),
                          ),
                          const SizedBox(width: 10),
                          FButton.icon(
                            variant: FButtonVariant.ghost,
                            size: FButtonSizeVariant.sm,
                            onPress: onDismissed,
                            child: const Icon(FLucideIcons.x, size: 18),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: GridView.builder(
                          itemCount: rail.items.length,
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 150,
                            mainAxisExtent: 246,
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
                          ),
                          itemBuilder: (context, index) {
                            final item = rail.items[index];
                            return _MediaGridTile(
                              item: item,
                              onPressed: () => onItemPressed(item),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaGridTile extends StatefulWidget {
  const _MediaGridTile({
    required this.item,
    required this.onPressed,
  });

  final MediaCatalogItem item;
  final VoidCallback onPressed;

  @override
  State<_MediaGridTile> createState() => _MediaGridTileState();
}

class _MediaGridTileState extends State<_MediaGridTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.1 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: FCard.raw(
          style: _darkCardStyle(
            context,
            hovered: _hovered,
            borderless: true,
          ),
          child: FTappable(
            onPress: widget.onPressed,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _MediaPoster(item: widget.item, wide: false),
                          if (widget.item.rating != null)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: FBadge(
                                child: Text(widget.item.rating!),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.typography.xs.copyWith(
                      color: context.theme.colors.foreground,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaPoster extends StatelessWidget {
  const _MediaPoster({
    required this.item,
    required this.wide,
  });

  final MediaCatalogItem item;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final posterUrl = item.posterUrl;
    if (posterUrl != null) {
      return CachedNetworkImage(
        imageUrl: posterUrl,
        fit: BoxFit.cover,
        placeholder: (_, __) => const Center(child: FCircularProgress()),
        errorWidget: (_, __, ___) => _PosterFallback(item: item, wide: wide),
      );
    }

    return _PosterFallback(item: item, wide: wide);
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({
    required this.item,
    required this.wide,
  });

  final MediaCatalogItem item;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF163A37), Color(0xFF111417)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            item.name,
            maxLines: wide ? 2 : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: wide ? 22 : 16,
              fontWeight: FontWeight.w900,
              shadows: const [
                Shadow(
                  blurRadius: 12,
                  color: Colors.black,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaRailData {
  const _MediaRailData({
    required this.title,
    required this.items,
    this.wide = false,
  });

  final String title;
  final List<MediaCatalogItem> items;
  final bool wide;
}

class _LiveTvCatalogPage extends StatelessWidget {
  const _LiveTvCatalogPage({
    required this.compact,
    required this.isLoading,
    required this.errorMessage,
    required this.categories,
    required this.channels,
    required this.channelView,
    required this.selectedCategory,
    required this.selectedStream,
    required this.favoriteStreamIds,
    required this.epgForStream,
    required this.isEpgLoading,
    required this.onSearchPressed,
    required this.onCategorySelected,
    required this.onChannelSelected,
    required this.onFavoriteToggled,
    required this.onEpgRequested,
  });

  final bool compact;
  final bool isLoading;
  final String? errorMessage;
  final List<LiveCategory> categories;
  final List<LiveStream> channels;
  final ChannelView channelView;
  final LiveCategory? selectedCategory;
  final LiveStream? selectedStream;
  final Set<String> favoriteStreamIds;
  final EpgProgram? Function(String streamId) epgForStream;
  final bool Function(String streamId) isEpgLoading;
  final VoidCallback onSearchPressed;
  final ValueChanged<LiveCategory> onCategorySelected;
  final ValueChanged<LiveStream> onChannelSelected;
  final ValueChanged<LiveStream> onFavoriteToggled;
  final ValueChanged<LiveStream> onEpgRequested;

  @override
  Widget build(BuildContext context) {
    final title = switch (channelView) {
      ChannelView.favorites => 'Favourites',
      ChannelView.recent => 'Recently viewed',
      ChannelView.category => 'Live TV',
    };

    return FCard.raw(
      style: _darkCardStyle(context),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                FAvatar.raw(
                  size: 34,
                  child: Icon(
                    FLucideIcons.monitorPlay,
                    size: 18,
                    color: context.theme.colors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.typography.xl.copyWith(
                      color: context.theme.colors.foreground,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SearchBarButton(
              label: 'Pretrazi kanale ili kategorije...',
              onPressed: onSearchPressed,
            ),
            const SizedBox(height: 14),
            Expanded(
              child: _ChannelBrowser(
                compact: compact,
                isLoading: isLoading,
                errorMessage: errorMessage,
                categories: categories,
                channels: channels,
                channelView: channelView,
                selectedCategory: selectedCategory,
                selectedStream: selectedStream,
                favoriteStreamIds: favoriteStreamIds,
                epgForStream: epgForStream,
                isEpgLoading: isEpgLoading,
                showSearchButton: false,
                onSearchPressed: onSearchPressed,
                onCategorySelected: onCategorySelected,
                onChannelSelected: onChannelSelected,
                onFavoriteToggled: onFavoriteToggled,
                onEpgRequested: onEpgRequested,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveCategoryPanel extends StatelessWidget {
  const _LiveCategoryPanel({
    required this.compact,
    required this.categories,
    required this.selectedCategory,
    required this.channelView,
    required this.onCategorySelected,
  });

  final bool compact;
  final List<LiveCategory> categories;
  final LiveCategory? selectedCategory;
  final ChannelView channelView;
  final ValueChanged<LiveCategory> onCategorySelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: categories.isEmpty
              ? const Center(
                  child: Text(
                    'Nema kategorija',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.builder(
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    final selected = channelView == ChannelView.category &&
                        category.categoryId == selectedCategory?.categoryId;

                    return _SidebarCategoryItem(
                      compact: compact,
                      label: category.categoryName,
                      selected: selected,
                      onTap: () => onCategorySelected(category),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ContentPanel extends StatelessWidget {
  const _ContentPanel({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FCard.raw(
      style: _darkCardStyle(context),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: context.theme.colors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.typography.sm.copyWith(
                      color: context.theme.colors.foreground,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _SidebarCategoryItem extends StatelessWidget {
  const _SidebarCategoryItem({
    required this.compact,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final bool compact;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: FItem(
        selected: selected,
        onPress: onTap,
        prefix: const Icon(FLucideIcons.tv, size: 15),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _PlayerPanel extends StatefulWidget {
  const _PlayerPanel({
    required this.controller,
    required this.player,
    required this.hasStream,
    required this.error,
    required this.isLive,
    required this.title,
    required this.onNext,
    required this.onWindowMode,
    required this.onFullscreen,
    required this.onExitDisplayMode,
    required this.displayMode,
  });

  final VideoController controller;
  final Player player;
  final bool hasStream;
  final String? error;
  final bool isLive;
  final String? title;
  final VoidCallback onNext;
  final VoidCallback onWindowMode;
  final VoidCallback onFullscreen;
  final VoidCallback onExitDisplayMode;
  final _PlayerDisplayMode displayMode;

  @override
  State<_PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<_PlayerPanel> {
  final FocusNode _focusNode = FocusNode();
  Timer? _hideControlsTimer;
  Timer? _centerPulseTimer;
  bool _controlsVisible = true;
  bool _centerPulseVisible = false;
  bool _volumeHover = false;
  double _lastVolume = 100;

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _centerPulseTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _showControls({bool autoHide = true}) {
    // Controls are intentionally transient: mouse movement or keyboard use
    // reveals them, then this timer fades them away so the video stays clean.
    _hideControlsTimer?.cancel();
    if (mounted) {
      setState(() => _controlsVisible = true);
    }
    if (autoHide && widget.hasStream) {
      _hideControlsTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && !_volumeHover) {
          setState(() => _controlsVisible = false);
        }
      });
    }
  }

  Future<void> _togglePlay() async {
    if (!widget.hasStream) {
      return;
    }
    _showControls();
    _pulseCenterControl();
    await widget.player.playOrPause();
  }

  void _pulseCenterControl() {
    // A short center pulse mirrors the familiar YouTube/Netflix feedback:
    // click or Space toggles playback, then the icon fades away.
    _centerPulseTimer?.cancel();
    setState(() => _centerPulseVisible = true);
    _centerPulseTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() => _centerPulseVisible = false);
      }
    });
  }

  Future<void> _toggleMute() async {
    final volume = widget.player.state.volume;
    if (volume > 0) {
      _lastVolume = volume;
      await widget.player.setVolume(0);
    } else {
      await widget.player.setVolume(_lastVolume <= 0 ? 70 : _lastVolume);
    }
    _showControls();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      child: MouseRegion(
        onEnter: (_) => _showControls(autoHide: false),
        onHover: (_) => _showControls(),
        onExit: (_) {
          if (widget.hasStream && !_volumeHover) {
            setState(() => _controlsVisible = false);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _focusNode.requestFocus();
            unawaited(_togglePlay());
          },
          child: _PlayerFrame(
            expanded: widget.displayMode != _PlayerDisplayMode.normal,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                widget.displayMode == _PlayerDisplayMode.normal ? 8 : 0,
              ),
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.hasStream)
                      Video(
                        controller: widget.controller,
                        controls: NoVideoControls,
                      ),
                    if (!widget.hasStream)
                      const Center(
                        child: Text(
                          'Izaberite kanal',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 20,
                          ),
                        ),
                      ),
                    _CenterPlayPulse(
                      player: widget.player,
                      visible: _centerPulseVisible,
                    ),
                    StreamBuilder<bool>(
                      stream: widget.player.stream.buffering,
                      initialData: widget.player.state.buffering,
                      builder: (context, snapshot) {
                        if (!widget.hasStream || snapshot.data != true) {
                          return const SizedBox.shrink();
                        }
                        return const Center(child: FCircularProgress());
                      },
                    ),
                    if (widget.hasStream)
                      _PlayerControls(
                        player: widget.player,
                        visible: _controlsVisible,
                        isLive: widget.isLive,
                        title: widget.title,
                        volumeHover: _volumeHover,
                        onVolumeHoverChanged: (value) {
                          setState(() => _volumeHover = value);
                          _showControls(autoHide: !value);
                        },
                        onPlayPause: _togglePlay,
                        onNext: widget.onNext,
                        onMute: _toggleMute,
                        onVolumeChanged: (value) {
                          _lastVolume = value;
                          widget.player.setVolume(value);
                        },
                        onFullscreen: widget.onFullscreen,
                        onWindowMode: widget.onWindowMode,
                        displayMode: widget.displayMode,
                      ),
                    if (widget.error != null)
                      Center(
                        child: FCard.raw(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'Stream trenutno nije dostupan',
                              style: context.theme.typography.sm.copyWith(
                                color: context.theme.colors.foreground,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.hasStream)
                      Positioned(
                        top: 34,
                        left: 16,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onExitDisplayMode,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Container(
                              width: 44,
                              height: 44,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.56),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                              child: const Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerFrame extends StatelessWidget {
  const _PlayerFrame({
    required this.expanded,
    required this.child,
  });

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (expanded) {
      return SizedBox.expand(child: child);
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: child,
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.player,
    required this.visible,
    required this.isLive,
    required this.title,
    required this.volumeHover,
    required this.onVolumeHoverChanged,
    required this.onPlayPause,
    required this.onNext,
    required this.onMute,
    required this.onVolumeChanged,
    required this.onFullscreen,
    required this.onWindowMode,
    required this.displayMode,
  });

  final Player player;
  final bool visible;
  final bool isLive;
  final String? title;
  final bool volumeHover;
  final ValueChanged<bool> onVolumeHoverChanged;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onMute;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onFullscreen;
  final VoidCallback onWindowMode;
  final _PlayerDisplayMode displayMode;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        ignoring: !visible,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: 0.25,
                  widthFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.18),
                          Colors.black.withValues(alpha: 0.86),
                        ],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!isLive && title != null) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _VodProgressBar(player: player),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        StreamBuilder<bool>(
                          stream: player.stream.playing,
                          initialData: player.state.playing,
                          builder: (context, snapshot) {
                            final playing = snapshot.data ?? false;
                            return _ControlIconButton(
                              tooltip: playing ? 'Pause' : 'Play',
                              icon: playing ? Icons.pause : Icons.play_arrow,
                              onPressed: onPlayPause,
                            );
                          },
                        ),
                        if (isLive)
                          _ControlIconButton(
                            tooltip: 'Sljedeci kanal',
                            icon: Icons.skip_next,
                            onPressed: onNext,
                          ),
                        _VolumeControl(
                          player: player,
                          hover: volumeHover,
                          onHoverChanged: onVolumeHoverChanged,
                          onMute: onMute,
                          onVolumeChanged: onVolumeChanged,
                        ),
                        const SizedBox(width: 8),
                        if (isLive) const _LiveLabel(),
                        const Spacer(),
                        _ControlIconButton(
                          tooltip: displayMode == _PlayerDisplayMode.window
                              ? 'Vrati player'
                              : 'Player preko prozora',
                          icon: displayMode == _PlayerDisplayMode.window
                              ? Icons.close_fullscreen
                              : Icons.fit_screen,
                          onPressed: onWindowMode,
                        ),
                        _ControlIconButton(
                          tooltip: displayMode == _PlayerDisplayMode.fullscreen
                              ? 'Izadji iz fullscreen'
                              : 'Fullscreen',
                          icon: displayMode == _PlayerDisplayMode.fullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          onPressed: onFullscreen,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.player,
    required this.hover,
    required this.onHoverChanged,
    required this.onMute,
    required this.onVolumeChanged,
  });

  final Player player;
  final bool hover;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onMute;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHoverChanged(true),
      onExit: (_) => onHoverChanged(false),
      child: Row(
        children: [
          StreamBuilder<double>(
            stream: player.stream.volume,
            initialData: player.state.volume,
            builder: (context, snapshot) {
              final volume = snapshot.data ?? 100;
              return _ControlIconButton(
                tooltip: volume == 0 ? 'Unmute' : 'Mute',
                icon: volume == 0
                    ? Icons.volume_off
                    : volume < 45
                        ? Icons.volume_down
                        : Icons.volume_up,
                onPressed: onMute,
              );
            },
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: hover ? 112 : 0,
            curve: Curves.easeOut,
            child: ClipRect(
              child: StreamBuilder<double>(
                stream: player.stream.volume,
                initialData: player.state.volume,
                builder: (context, snapshot) {
                  return SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      value: (snapshot.data ?? 100).clamp(0, 100).toDouble(),
                      max: 100,
                      onChanged: onVolumeChanged,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveLabel extends StatelessWidget {
  const _LiveLabel();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Color(0xFFFF3B30),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          'LIVE',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _VodProgressBar extends StatelessWidget {
  const _VodProgressBar({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, positionSnapshot) {
            final rawPosition = positionSnapshot.data ?? Duration.zero;
            final position = rawPosition > duration && duration > Duration.zero
                ? duration
                : rawPosition;
            final max = duration.inMilliseconds <= 0
                ? 1.0
                : duration.inMilliseconds.toDouble();
            final value = position.inMilliseconds.clamp(0, max).toDouble();

            return Row(
              children: [
                Text(
                  _formatPlaybackTime(position),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      value: value,
                      max: max,
                      onChanged: duration.inMilliseconds <= 0
                          ? null
                          : (next) {
                              player.seek(
                                Duration(milliseconds: next.round()),
                              );
                            },
                    ),
                  ),
                ),
                Text(
                  _formatPlaybackTime(duration),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

String _formatPlaybackTime(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '${value.inMinutes}:$seconds';
}

class _CenterPlayPulse extends StatelessWidget {
  const _CenterPlayPulse({
    required this.player,
    required this.visible,
  });

  final Player player;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snapshot) {
        final playing = snapshot.data ?? false;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Center(
              child: AnimatedScale(
                scale: visible ? 1 : 0.86,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.48),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 46,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ControlIconButton extends StatelessWidget {
  const _ControlIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: Colors.white,
      icon: Icon(icon, size: 24),
      onPressed: onPressed,
    );
  }
}

class _ChannelBrowser extends StatelessWidget {
  const _ChannelBrowser({
    required this.compact,
    required this.isLoading,
    required this.errorMessage,
    required this.categories,
    required this.channels,
    required this.channelView,
    required this.selectedCategory,
    required this.selectedStream,
    required this.favoriteStreamIds,
    required this.epgForStream,
    required this.isEpgLoading,
    this.showSearchButton = true,
    required this.onSearchPressed,
    required this.onCategorySelected,
    required this.onChannelSelected,
    required this.onFavoriteToggled,
    required this.onEpgRequested,
  });

  final bool compact;
  final bool isLoading;
  final String? errorMessage;
  final List<LiveCategory> categories;
  final List<LiveStream> channels;
  final ChannelView channelView;
  final LiveCategory? selectedCategory;
  final LiveStream? selectedStream;
  final Set<String> favoriteStreamIds;
  final EpgProgram? Function(String streamId) epgForStream;
  final bool Function(String streamId) isEpgLoading;
  final bool showSearchButton;
  final VoidCallback onSearchPressed;
  final ValueChanged<LiveCategory> onCategorySelected;
  final ValueChanged<LiveStream> onChannelSelected;
  final ValueChanged<LiveStream> onFavoriteToggled;
  final ValueChanged<LiveStream> onEpgRequested;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: FCircularProgress());
    }

    if (errorMessage != null) {
      return Center(child: Text(errorMessage!));
    }

    final categoryWidth = compact ? 240.0 : 290.0;
    final gap = compact ? 10.0 : 14.0;
    final channelTitle = switch (channelView) {
      ChannelView.favorites => 'Kanali - Favourites',
      ChannelView.recent => 'Kanali - Recently viewed',
      ChannelView.category =>
        'Kanali - ${selectedCategory?.categoryName ?? 'Sve kategorije'}',
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: categoryWidth,
          child: Column(
            children: [
              if (showSearchButton) ...[
                FButton(
                  variant: FButtonVariant.outline,
                  onPress: onSearchPressed,
                  prefix: const Icon(FLucideIcons.search, size: 17),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Pretraga',
                        style: context.theme.typography.sm.copyWith(
                          color: context.theme.colors.mutedForeground,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Icon(FLucideIcons.command, size: 15),
                    ],
                  ),
                ),
                SizedBox(height: compact ? 8 : 10),
              ],
              Expanded(
                child: _ContentPanel(
                  title: 'Kategorije',
                  icon: FLucideIcons.layers,
                  child: _LiveCategoryPanel(
                    compact: compact,
                    categories: categories,
                    selectedCategory: selectedCategory,
                    channelView: channelView,
                    onCategorySelected: onCategorySelected,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: gap),
        Expanded(
          child: _ContentPanel(
            title: channelTitle,
            icon: FLucideIcons.listVideo,
            child: channels.isEmpty
                ? const Center(child: Text('Nema kanala za prikaz'))
                : ListView.builder(
                    itemCount: channels.length,
                    itemBuilder: (context, index) {
                      final channel = channels[index];
                      final selected =
                          channel.streamId == selectedStream?.streamId;
                      return Padding(
                        padding: EdgeInsets.only(bottom: compact ? 8 : 10),
                        child: _ChannelCard(
                          compact: compact,
                          channel: channel,
                          selected: selected,
                          favorite:
                              favoriteStreamIds.contains(channel.streamId),
                          epg: epgForStream(channel.streamId),
                          epgLoading: isEpgLoading(channel.streamId),
                          onTap: () => onChannelSelected(channel),
                          onFavoriteToggled: () => onFavoriteToggled(channel),
                          onEpgRequested: () => onEpgRequested(channel),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _MediaSearchOverlay extends StatefulWidget {
  const _MediaSearchOverlay({
    required this.section,
    required this.categories,
    required this.items,
    required this.onDismissed,
    required this.onItemSelected,
  });

  final _LibrarySection section;
  final List<LiveCategory> categories;
  final List<MediaCatalogItem> items;
  final VoidCallback onDismissed;
  final ValueChanged<MediaCatalogItem> onItemSelected;

  @override
  State<_MediaSearchOverlay> createState() => _MediaSearchOverlayState();
}

class _MediaSearchOverlayState extends State<_MediaSearchOverlay> {
  LiveCategory? _selectedCategory;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final isMovies = widget.section == _LibrarySection.movies;
    final query = _query.toLowerCase().trim();
    final results = widget.items
        .where(
          (item) {
            final matchesCategory = _selectedCategory == null ||
                item.categoryId == _selectedCategory!.categoryId;
            final matchesQuery =
                query.isEmpty || item.name.toLowerCase().contains(query);
            return matchesCategory && matchesQuery;
          },
        )
        .take(80)
        .toList(growable: false);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onDismissed,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.52),
              ),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 520),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        isMovies
                            ? FLucideIcons.film
                            : FLucideIcons.clapperboard,
                        size: 20,
                        color: context.theme.colors.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isMovies ? 'Pretraga filmova' : 'Pretraga serija',
                          style: context.theme.typography.lg.copyWith(
                            color: context.theme.colors.foreground,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      FButton.icon(
                        variant: FButtonVariant.ghost,
                        size: FButtonSizeVariant.sm,
                        onPress: widget.onDismissed,
                        child: const Icon(FLucideIcons.x, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      SizedBox(
                        width: 240,
                        child: FSelect<String>(
                          items: {
                            'Sve kategorije': '',
                            for (final category in widget.categories)
                              category.categoryName: category.categoryId,
                          },
                          control: FSelectControl.managed(
                            initial: _selectedCategory?.categoryId ?? '',
                            onChange: (value) {
                              if (value != null) {
                                setState(() {
                                  _selectedCategory = value.isEmpty
                                      ? null
                                      : widget.categories
                                          .where(
                                            (category) =>
                                                category.categoryId == value,
                                          )
                                          .firstOrNull;
                                  _query = '';
                                });
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FTextField(
                          autofocus: true,
                          control: FTextFieldControl.managed(
                            onChange: (value) {
                              setState(() => _query = value.text);
                            },
                          ),
                          hint: isMovies
                              ? 'Pretrazi filmove...'
                              : 'Pretrazi serije...',
                          prefixBuilder: (context, style, variants) =>
                              FTextField.prefixIconBuilder(
                            context,
                            style,
                            variants,
                            const Icon(FLucideIcons.search, size: 17),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: results.isEmpty
                        ? const Center(child: Text('Nema rezultata'))
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              decoration: BoxDecoration(
                                color: context.theme.colors.background
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: context.theme.colors.border
                                      .withValues(alpha: 0.1),
                                ),
                              ),
                              child: ListView.separated(
                                shrinkWrap: true,
                                itemCount: results.length,
                                padding: const EdgeInsets.all(8),
                                separatorBuilder: (context, index) => Divider(
                                  color: context.theme.colors.border
                                      .withValues(alpha: 0.15),
                                  height: 1,
                                  indent: 72,
                                ),
                                itemBuilder: (context, index) {
                                  final item = results[index];
                                  return _MediaSearchResultTile(
                                    item: item,
                                    fallbackIcon: isMovies
                                        ? FLucideIcons.film
                                        : FLucideIcons.clapperboard,
                                    onPressed: () =>
                                        widget.onItemSelected(item),
                                  );
                                },
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaSearchResultTile extends StatefulWidget {
  const _MediaSearchResultTile({
    required this.item,
    required this.fallbackIcon,
    required this.onPressed,
  });

  final MediaCatalogItem item;
  final IconData fallbackIcon;
  final VoidCallback onPressed;

  @override
  State<_MediaSearchResultTile> createState() => _MediaSearchResultTileState();
}

class _MediaSearchResultTileState extends State<_MediaSearchResultTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.045 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          margin: EdgeInsets.symmetric(
            horizontal: _hovered ? 0 : 8,
            vertical: _hovered ? 3 : 0,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: _hovered ? 10 : 0,
                sigmaY: _hovered ? 10 : 0,
              ),
              child: ColoredBox(
                color: _hovered
                    ? Colors.black.withValues(alpha: 0.34)
                    : Colors.transparent,
                child: FTappable(
                  onPress: widget.onPressed,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: _hovered ? 12 : 8,
                      vertical: _hovered ? 12 : 8,
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 54,
                            height: 72,
                            child: widget.item.posterUrl == null
                                ? DecoratedBox(
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF111417),
                                    ),
                                    child: Icon(
                                      widget.fallbackIcon,
                                      color:
                                          context.theme.colors.mutedForeground,
                                      size: 22,
                                    ),
                                  )
                                : CachedNetworkImage(
                                    imageUrl: widget.item.posterUrl!,
                                    fit: BoxFit.cover,
                                    placeholder: (_, __) => const Center(
                                      child: FCircularProgress(),
                                    ),
                                    errorWidget: (_, __, ___) => DecoratedBox(
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF111417),
                                      ),
                                      child: Icon(
                                        widget.fallbackIcon,
                                        color: context
                                            .theme.colors.mutedForeground,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.item.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.theme.typography.sm.copyWith(
                                  color: context.theme.colors.foreground,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.item.rating == null
                                    ? 'Xtream katalog'
                                    : 'Rating ${widget.item.rating}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.theme.typography.xs.copyWith(
                                  color: context.theme.colors.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          FLucideIcons.play,
                          size: 18,
                          color: context.theme.colors.mutedForeground,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchOverlay extends StatefulWidget {
  const _SearchOverlay({
    required this.categories,
    required this.streams,
    required this.favoriteStreamIds,
    required this.onDismissed,
    required this.onFavoriteToggled,
    required this.onCategorySelected,
    required this.onStreamSelected,
  });

  final List<LiveCategory> categories;
  final List<LiveStream> streams;
  final Set<String> favoriteStreamIds;
  final VoidCallback onDismissed;
  final ValueChanged<LiveStream> onFavoriteToggled;
  final ValueChanged<LiveCategory> onCategorySelected;
  final ValueChanged<LiveStream> onStreamSelected;

  @override
  State<_SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends State<_SearchOverlay> {
  _SearchScope _scope = _SearchScope.channels;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase().trim();
    final categories = widget.categories
        .where(
          (category) =>
              query.isEmpty ||
              category.categoryName.toLowerCase().contains(query),
        )
        .take(40)
        .toList(growable: false);
    final streams = widget.streams
        .where(
          (stream) =>
              query.isEmpty || stream.name.toLowerCase().contains(query),
        )
        .take(60)
        .toList(growable: false);
    final showingCategories = _scope == _SearchScope.categories;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onDismissed,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.52),
              ),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 400),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        FLucideIcons.search,
                        size: 20,
                        color: context.theme.colors.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Pretraga',
                          style: context.theme.typography.lg.copyWith(
                            color: context.theme.colors.foreground,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      FButton.icon(
                        variant: FButtonVariant.ghost,
                        size: FButtonSizeVariant.sm,
                        onPress: widget.onDismissed,
                        child: const Icon(FLucideIcons.x, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      SizedBox(
                        width: 180,
                        child: FSelect<_SearchScope>(
                          items: const {
                            'Kanali': _SearchScope.channels,
                            'Kategorije': _SearchScope.categories,
                          },
                          control: FSelectControl.managed(
                            initial: _scope,
                            onChange: (value) {
                              if (value != null) {
                                setState(() => _scope = value);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FTextField(
                          autofocus: true,
                          control: FTextFieldControl.managed(
                            onChange: (value) {
                              setState(() => _query = value.text);
                            },
                          ),
                          hint: showingCategories
                              ? 'Pretrazi kategorije...'
                              : 'Pretrazi kanale...',
                          prefixBuilder: (context, style, variants) =>
                              FTextField.prefixIconBuilder(
                            context,
                            style,
                            variants,
                            const Icon(FLucideIcons.search, size: 17),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: showingCategories
                        ? _SearchCategoryResults(
                            categories: categories,
                            onSelected: widget.onCategorySelected,
                          )
                        : _SearchStreamResults(
                            streams: streams,
                            favoriteStreamIds: widget.favoriteStreamIds,
                            onSelected: widget.onStreamSelected,
                            onFavoriteToggled: widget.onFavoriteToggled,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchCategoryResults extends StatelessWidget {
  const _SearchCategoryResults({
    required this.categories,
    required this.onSelected,
  });

  final List<LiveCategory> categories;
  final ValueChanged<LiveCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return const Center(child: Text('Nema rezultata'));
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: context.theme.colors.background.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: context.theme.colors.border.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: categories.length,
          padding: const EdgeInsets.only(
            right: 20.0,
            left: 8.0,
            top: 8.0,
            bottom: 8.0,
          ),
          separatorBuilder: (context, index) => Divider(
            color: context.theme.colors.border.withValues(alpha: 0.15),
            height: 1,
            indent: 48,
          ),
          itemBuilder: (context, index) {
            final category = categories[index];
            return _LiveSearchResultTile(
              icon: FLucideIcons.layers,
              title: category.categoryName,
              subtitle: 'Kategorija',
              onPress: () => onSelected(category),
            );
          },
        ),
      ),
    );
  }
}

class _SearchStreamResults extends StatelessWidget {
  const _SearchStreamResults({
    required this.streams,
    required this.favoriteStreamIds,
    required this.onSelected,
    required this.onFavoriteToggled,
  });

  final List<LiveStream> streams;
  final Set<String> favoriteStreamIds;
  final ValueChanged<LiveStream> onSelected;
  final ValueChanged<LiveStream> onFavoriteToggled;

  @override
  Widget build(BuildContext context) {
    if (streams.isEmpty) {
      return const Center(child: Text('Nema rezultata'));
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: context.theme.colors.background.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: context.theme.colors.border.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: streams.length,
          padding: const EdgeInsets.only(
            right: 20.0,
            left: 8.0,
            top: 8.0,
            bottom: 8.0,
          ),
          separatorBuilder: (context, index) => Divider(
            color: context.theme.colors.border.withValues(alpha: 0.15),
            height: 1,
            indent: 64,
          ),
          itemBuilder: (context, index) {
            final stream = streams[index];
            final favorite = favoriteStreamIds.contains(stream.streamId);
            return _LiveSearchResultTile(
              logoUrl: stream.streamIcon,
              title: stream.name,
              subtitle: 'Live kanal',
              favorite: favorite,
              onFavoritePressed: () => onFavoriteToggled(stream),
              onPress: () => onSelected(stream),
            );
          },
        ),
      ),
    );
  }
}

class _LiveSearchResultTile extends StatefulWidget {
  const _LiveSearchResultTile({
    required this.title,
    required this.subtitle,
    required this.onPress,
    this.icon,
    this.logoUrl,
    this.favorite = false,
    this.onFavoritePressed,
  });

  final String title;
  final String subtitle;
  final VoidCallback onPress;
  final IconData? icon;
  final String? logoUrl;
  final bool favorite;
  final VoidCallback? onFavoritePressed;

  @override
  State<_LiveSearchResultTile> createState() => _LiveSearchResultTileState();
}

class _LiveSearchResultTileState extends State<_LiveSearchResultTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.045 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          margin: EdgeInsets.symmetric(
            horizontal: _hovered ? 0 : 8,
            vertical: _hovered ? 3 : 0,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: _hovered ? 10 : 0,
                sigmaY: _hovered ? 10 : 0,
              ),
              child: ColoredBox(
                color: _hovered
                    ? Colors.black.withValues(alpha: 0.34)
                    : Colors.transparent,
                child: FTappable(
                  onPress: widget.onPress,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: _hovered ? 12 : 8,
                      vertical: _hovered ? 12 : 8,
                    ),
                    child: Row(
                      children: [
                        if (widget.logoUrl != null)
                          _ChannelLogo(imageUrl: widget.logoUrl)
                        else
                          FAvatar.raw(
                            size: 40,
                            child: Icon(
                              widget.icon ?? FLucideIcons.search,
                              size: 18,
                              color: context.theme.colors.mutedForeground,
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.theme.typography.sm.copyWith(
                                  color: context.theme.colors.foreground,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                widget.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.theme.typography.xs.copyWith(
                                  color: context.theme.colors.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (widget.onFavoritePressed != null)
                          Tooltip(
                            message: widget.favorite
                                ? 'Ukloni iz favorita'
                                : 'Dodaj u favorite',
                            child: FButton.icon(
                              variant: FButtonVariant.ghost,
                              size: FButtonSizeVariant.sm,
                              onPress: widget.onFavoritePressed,
                              child: Icon(
                                widget.favorite
                                    ? FLucideIcons.star
                                    : FLucideIcons.starOff,
                                color: widget.favorite
                                    ? const Color(0xFFFFD166)
                                    : context.theme.colors.mutedForeground,
                                size: 18,
                              ),
                            ),
                          )
                        else
                          Icon(
                            FLucideIcons.chevronRight,
                            size: 18,
                            color: context.theme.colors.mutedForeground,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelCard extends StatefulWidget {
  const _ChannelCard({
    required this.compact,
    required this.channel,
    required this.selected,
    required this.favorite,
    required this.epg,
    required this.epgLoading,
    required this.onTap,
    required this.onFavoriteToggled,
    required this.onEpgRequested,
  });

  final bool compact;
  final LiveStream channel;
  final bool selected;
  final bool favorite;
  final EpgProgram? epg;
  final bool epgLoading;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggled;
  final VoidCallback onEpgRequested;

  @override
  State<_ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<_ChannelCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onEpgRequested();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ChannelCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel.streamId != widget.channel.streamId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onEpgRequested();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FCard.raw(
      style: _darkCardStyle(context, selected: widget.selected),
      child: FTappable(
        onPress: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: widget.compact ? 8 : 10,
          ),
          child: Row(
            children: [
              _ChannelLogo(imageUrl: widget.channel.streamIcon),
              const SizedBox(width: 12),
              SizedBox(
                width: widget.compact ? 160 : 220,
                child: Text(
                  widget.channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.typography.sm.copyWith(
                    color: widget.selected
                        ? context.theme.colors.primary
                        : context.theme.colors.foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _EpgLine(
                  epg: widget.epg,
                  loading: widget.epgLoading,
                ),
              ),
              Tooltip(
                message:
                    widget.favorite ? 'Ukloni iz favorita' : 'Dodaj u favorite',
                child: FButton.icon(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  onPress: widget.onFavoriteToggled,
                  child: Icon(
                    widget.favorite ? FLucideIcons.star : FLucideIcons.starOff,
                    color: widget.favorite
                        ? const Color(0xFFFFD166)
                        : context.theme.colors.mutedForeground,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EpgLine extends StatelessWidget {
  const _EpgLine({
    required this.epg,
    required this.loading,
  });

  final EpgProgram? epg;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final program = epg;
    if (loading) {
      return const _EpgPlaceholder(
        icon: FLucideIcons.refreshCw,
        text: 'Ucitavam EPG...',
      );
    }

    if (program == null) {
      return const _EpgPlaceholder(
        icon: FLucideIcons.calendarX,
        text: 'Nema EPG podataka',
      );
    }

    final timeRange = _formatEpgRange(program);
    return FCard.raw(
      style: _darkCardStyle(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (timeRange != null) ...[
              FBadge(
                variant: FBadgeVariant.secondary,
                child: Text(
                  timeRange,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                program.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.xs.copyWith(
                  color: context.theme.colors.mutedForeground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpgPlaceholder extends StatelessWidget {
  const _EpgPlaceholder({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return FCard.raw(
      style: _darkCardStyle(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 15, color: context.theme.colors.mutedForeground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.xs.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _formatEpgRange(EpgProgram program) {
  final start = program.start;
  final end = program.end;
  if (start == null || end == null) {
    return null;
  }

  String time(DateTime value) {
    return '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
  }

  return '${time(start)}-${time(end)}';
}

class _ChannelLogo extends StatelessWidget {
  const _ChannelLogo({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;

    return FAvatar.raw(
      size: 48,
      child: url == null
          ? const Icon(FLucideIcons.tv, size: 24)
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (_, __) => const SizedBox.square(
                dimension: 18,
                child: FCircularProgress(),
              ),
              errorWidget: (_, __, ___) =>
                  const Icon(FLucideIcons.tv, size: 24),
            ),
    );
  }
}
