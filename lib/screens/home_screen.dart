import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/epg_program.dart';
import '../models/live_category.dart';
import '../models/live_stream.dart';
import '../providers/auth_provider.dart';
import '../providers/iptv_provider.dart';

enum _PlayerDisplayMode {
  normal,
  window,
  fullscreen,
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
  String? _activeUrl;
  String? _playerError;
  String _categoryQuery = '';
  _PlayerDisplayMode _playerDisplayMode = _PlayerDisplayMode.normal;

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
      setState(() => _playerDisplayMode = _PlayerDisplayMode.normal);
      _keyboardFocusNode.requestFocus();
    }
  }

  Future<void> _setPlayerDisplayMode(_PlayerDisplayMode mode) async {
    await windowManager.setFullScreen(mode == _PlayerDisplayMode.fullscreen);
    if (mounted) {
      setState(() => _playerDisplayMode = mode);
    }
  }

  Future<void> _exitPlayerDisplayMode() {
    return _setPlayerDisplayMode(_PlayerDisplayMode.normal);
  }

  Future<void> _toggleWindowPlayerMode() {
    return _setPlayerDisplayMode(
      _playerDisplayMode == _PlayerDisplayMode.window
          ? _PlayerDisplayMode.normal
          : _PlayerDisplayMode.window,
    );
  }

  Future<void> _toggleSystemPlayerFullscreen() {
    return _setPlayerDisplayMode(
      _playerDisplayMode == _PlayerDisplayMode.fullscreen
          ? _PlayerDisplayMode.normal
          : _PlayerDisplayMode.fullscreen,
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
    if (_activeUrl == null) {
      return;
    }
    await _player.playOrPause();
  }

  Future<void> _seekBy(Duration delta) async {
    if (_activeUrl == null) {
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

  KeyEventResult _handleGlobalKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    return _handlePlayerShortcut(event.logicalKey)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
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
    context.read<IptvProvider>().selectStream(
          stream: channels[nextIndex],
          serverUrl: auth.serverUrl!,
          username: auth.username!,
          password: auth.password!,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final iptv = context.watch<IptvProvider>();
    final visibleCategories = iptv.categories.where((category) {
      final query = _categoryQuery.toLowerCase().trim();
      return query.isEmpty ||
          category.categoryName.toLowerCase().contains(query);
    }).toList(growable: false);

    final playerUrl = iptv.playerUrl;
    if (playerUrl != null && playerUrl != _activeUrl) {
      _activeUrl = playerUrl;
      _playerError = null;
      unawaited(_player.open(Media(playerUrl)));
    }

    return Scaffold(
      body: Focus(
        focusNode: _keyboardFocusNode,
        autofocus: true,
        onKeyEvent: _handleGlobalKey,
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, windowConstraints) {
                final compact = windowConstraints.maxWidth < 980 ||
                    windowConstraints.maxHeight < 680;
                final sidebarWidth = compact ? 280.0 : 340.0;
                final pagePadding = compact ? 12.0 : 20.0;
                final sectionGap = compact ? 10.0 : 14.0;

                return Row(
                  children: [
                    _CategorySidebar(
                      width: sidebarWidth,
                      compact: compact,
                      channelView: iptv.channelView,
                      favoritesCount: iptv.favoritesCount,
                      recentCount: iptv.recentCount,
                      categories: visibleCategories,
                      selectedCategory: iptv.selectedCategory,
                      onFavoritesSelected:
                          context.read<IptvProvider>().selectFavorites,
                      onRecentSelected:
                          context.read<IptvProvider>().selectRecent,
                      onSearchChanged: (value) {
                        setState(() => _categoryQuery = value);
                      },
                      onCategorySelected:
                          context.read<IptvProvider>().selectCategory,
                      onLogout: () async {
                        await _player.stop();
                        if (!context.mounted) {
                          return;
                        }
                        context.read<IptvProvider>().reset();
                        await context.read<AuthProvider>().logout();
                      },
                    ),
                    Expanded(
                      child: SafeArea(
                        child: Padding(
                          padding: EdgeInsets.all(pagePadding),
                          child: Column(
                            children: [
                              Expanded(
                                child: Center(
                                  child: _playerDisplayMode !=
                                          _PlayerDisplayMode.normal
                                      ? const ColoredBox(
                                          color: Colors.black,
                                          child: SizedBox.expand(),
                                        )
                                      : _PlayerPanel(
                                          controller: _videoController,
                                          player: _player,
                                          hasStream: playerUrl != null,
                                          error: _playerError,
                                          displayMode:
                                              _PlayerDisplayMode.normal,
                                          onWindowMode: _toggleWindowPlayerMode,
                                          onFullscreen:
                                              _toggleSystemPlayerFullscreen,
                                          onExitDisplayMode:
                                              _exitPlayerDisplayMode,
                                          onNext: () =>
                                              _playNextChannel(auth, iptv),
                                        ),
                                ),
                              ),
                              SizedBox(height: sectionGap),
                              Expanded(
                                child: _ChannelBrowser(
                                  compact: compact,
                                  isLoading: iptv.isLoading,
                                  errorMessage: iptv.errorMessage,
                                  channels: iptv.filteredStreams,
                                  selectedStream: iptv.selectedStream,
                                  favoriteStreamIds: iptv.favoriteStreamIds,
                                  epgForStream: iptv.epgForStream,
                                  isEpgLoading: iptv.isEpgLoading,
                                  searchAllChannels: iptv.searchAllChannels,
                                  onSearchChanged: context
                                      .read<IptvProvider>()
                                      .setSearchQuery,
                                  onSearchScopeChanged: context
                                      .read<IptvProvider>()
                                      .setSearchAllChannels,
                                  onChannelSelected: (stream) {
                                    context.read<IptvProvider>().selectStream(
                                          stream: stream,
                                          serverUrl: auth.serverUrl!,
                                          username: auth.username!,
                                          password: auth.password!,
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
                            ],
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
                    displayMode: _playerDisplayMode,
                    onWindowMode: _toggleWindowPlayerMode,
                    onFullscreen: _toggleSystemPlayerFullscreen,
                    onExitDisplayMode: _exitPlayerDisplayMode,
                    onNext: () => _playNextChannel(auth, iptv),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategorySidebar extends StatelessWidget {
  const _CategorySidebar({
    required this.width,
    required this.compact,
    required this.channelView,
    required this.favoritesCount,
    required this.recentCount,
    required this.categories,
    required this.selectedCategory,
    required this.onFavoritesSelected,
    required this.onRecentSelected,
    required this.onSearchChanged,
    required this.onCategorySelected,
    required this.onLogout,
  });

  final double width;
  final bool compact;
  final ChannelView channelView;
  final int favoritesCount;
  final int recentCount;
  final List<LiveCategory> categories;
  final LiveCategory? selectedCategory;
  final VoidCallback onFavoritesSelected;
  final VoidCallback onRecentSelected;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<LiveCategory> onCategorySelected;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: const Color(0xFF171A1D),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 18,
                compact ? 14 : 20,
                compact ? 12 : 18,
                8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Biblioteka',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                children: [
                  _SidebarShortcut(
                    icon: Icons.star,
                    label: 'Favourites',
                    count: favoritesCount,
                    selected: channelView == ChannelView.favorites,
                    compact: compact,
                    onTap: onFavoritesSelected,
                  ),
                  _SidebarShortcut(
                    icon: Icons.history,
                    label: 'Recently viewed',
                    count: recentCount,
                    selected: channelView == ChannelView.recent,
                    compact: compact,
                    onTap: onRecentSelected,
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 18,
                compact ? 10 : 14,
                compact ? 12 : 18,
                8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Kategorije',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(10, 0, 10, compact ? 8 : 12),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Pretraga kategorija',
                  isDense: true,
                ),
                onChanged: onSearchChanged,
              ),
            ),
            Expanded(
              child: categories.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                          'Nema kategorija',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: categories.length,
                      itemBuilder: (context, index) {
                        final category = categories[index];
                        final selected = channelView == ChannelView.category &&
                            category.categoryId == selectedCategory?.categoryId;

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            hoverColor: Colors.white.withValues(alpha: 0.06),
                            onTap: () => onCategorySelected(category),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: compact ? 9 : 11,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.16)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                category.categoryName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.white70,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: EdgeInsets.all(compact ? 10 : 14),
              child: OutlinedButton.icon(
                onPressed: onLogout,
                icon: const Icon(Icons.logout),
                label: const Text('Logout'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarShortcut extends StatelessWidget {
  const _SidebarShortcut({
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: Colors.white.withValues(alpha: 0.06),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: compact ? 9 : 11,
          ),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white70,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white70,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              Text(
                count.toString(),
                style: TextStyle(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
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

  Future<void> _seekBy(Duration delta) async {
    if (!widget.hasStream) {
      return;
    }
    final nextPosition = widget.player.state.position + delta;
    await widget.player.seek(
      nextPosition.isNegative ? Duration.zero : nextPosition,
    );
    _showControls();
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

  Future<void> _changeVolume(double delta) async {
    final nextVolume = (widget.player.state.volume + delta).clamp(0, 100);
    if (nextVolume > 0) {
      _lastVolume = nextVolume.toDouble();
    }
    await widget.player.setVolume(nextVolume.toDouble());
    _showControls();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        unawaited(_togglePlay());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        unawaited(_seekBy(const Duration(seconds: 10)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        unawaited(_seekBy(const Duration(seconds: -10)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        unawaited(_changeVolume(5));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        unawaited(_changeVolume(-5));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        unawaited(_toggleMute());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        widget.onFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (widget.displayMode != _PlayerDisplayMode.normal) {
          widget.onExitDisplayMode();
          return KeyEventResult.handled;
        }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
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
                        return const Center(
                          child: SizedBox.square(
                            dimension: 38,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Colors.white,
                            ),
                          ),
                        );
                      },
                    ),
                    if (widget.hasStream)
                      _PlayerControls(
                        player: widget.player,
                        visible: _controlsVisible,
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
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.78),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'Stream trenutno nije dostupan',
                              style: TextStyle(color: Colors.white),
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
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                const Color(0xFF101214).withValues(alpha: 0.18),
                const Color(0xFF101214).withValues(alpha: 0.86),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
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
                    const _LiveLabel(),
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
            width: hover ? 92 : 0,
            curve: Curves.easeOut,
            child: ClipRect(
              child: StreamBuilder<double>(
                stream: player.stream.volume,
                initialData: player.state.volume,
                builder: (context, snapshot) {
                  return Slider(
                    value: (snapshot.data ?? 100).clamp(0, 100).toDouble(),
                    max: 100,
                    onChanged: onVolumeChanged,
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
    required this.channels,
    required this.selectedStream,
    required this.favoriteStreamIds,
    required this.epgForStream,
    required this.isEpgLoading,
    required this.searchAllChannels,
    required this.onSearchChanged,
    required this.onSearchScopeChanged,
    required this.onChannelSelected,
    required this.onFavoriteToggled,
    required this.onEpgRequested,
  });

  final bool compact;
  final bool isLoading;
  final String? errorMessage;
  final List<LiveStream> channels;
  final LiveStream? selectedStream;
  final Set<String> favoriteStreamIds;
  final EpgProgram? Function(String streamId) epgForStream;
  final bool Function(String streamId) isEpgLoading;
  final bool searchAllChannels;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<bool> onSearchScopeChanged;
  final ValueChanged<LiveStream> onChannelSelected;
  final ValueChanged<LiveStream> onFavoriteToggled;
  final ValueChanged<LiveStream> onEpgRequested;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (errorMessage != null) {
      return Center(child: Text(errorMessage!));
    }

    return Column(
      children: [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'Pretraga kanala',
            isDense: true,
          ),
          onChanged: onSearchChanged,
        ),
        SizedBox(height: compact ? 8 : 10),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<bool>(
            style: compact
                ? const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  )
                : null,
            segments: const [
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Icons.folder),
                label: Text('Kategorija'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Icons.public),
                label: Text('Svi kanali'),
              ),
            ],
            selected: {searchAllChannels},
            onSelectionChanged: (selection) {
              onSearchScopeChanged(selection.first);
            },
          ),
        ),
        SizedBox(height: compact ? 8 : 12),
        Expanded(
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
                        favorite: favoriteStreamIds.contains(channel.streamId),
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
      ],
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
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      hoverColor: Colors.white.withValues(alpha: 0.05),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: widget.compact ? 8 : 10,
        ),
        decoration: BoxDecoration(
          color: widget.selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
              : const Color(0xFF181C20),
          border: Border.all(
            color: widget.selected
                ? Theme.of(context).colorScheme.primary
                : Colors.white.withValues(alpha: 0.08),
          ),
          borderRadius: BorderRadius.circular(8),
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
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _EpgLine(
                epg: widget.epg,
                loading: widget.epgLoading,
              ),
            ),
            IconButton(
              tooltip:
                  widget.favorite ? 'Ukloni iz favorita' : 'Dodaj u favorite',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onFavoriteToggled,
              icon: Icon(
                widget.favorite ? Icons.star : Icons.star_border,
                color: widget.favorite
                    ? const Color(0xFFFFD166)
                    : Colors.white.withValues(alpha: 0.62),
              ),
            ),
          ],
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
        icon: Icons.sync,
        text: 'Ucitavam EPG...',
      );
    }

    if (program == null) {
      return const _EpgPlaceholder(
        icon: Icons.event_busy,
        text: 'Nema EPG podataka',
      );
    }

    final timeRange = _formatEpgRange(program);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          if (timeRange != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
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
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
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
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: Colors.white38),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
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

    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? const Icon(Icons.tv, size: 24)
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (_, __) => const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              errorWidget: (_, __, ___) => const Icon(Icons.tv, size: 24),
            ),
    );
  }
}
