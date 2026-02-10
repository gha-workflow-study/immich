import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/scroll_extensions.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/download_status_floating_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.provider.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_stack.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.state.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/top_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_controls_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_value_provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/current_asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/widgets/common/immich_loading_indicator.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view_gallery.dart';

@RoutePage()
class AssetViewerPage extends StatelessWidget {
  final int initialIndex;
  final TimelineService timelineService;
  final int? heroOffset;
  final RemoteAlbum? currentAlbum;

  const AssetViewerPage({
    super.key,
    required this.initialIndex,
    required this.timelineService,
    this.heroOffset,
    this.currentAlbum,
  });

  @override
  Widget build(BuildContext context) {
    // This is necessary to ensure that the timeline service is available
    // since the Timeline and AssetViewer are on different routes / Widget subtrees.
    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWithValue(timelineService),
        currentRemoteAlbumScopedProvider.overrideWithValue(currentAlbum),
      ],
      child: AssetViewer(initialIndex: initialIndex, heroOffset: heroOffset),
    );
  }
}

class AssetViewer extends ConsumerStatefulWidget {
  final int initialIndex;
  final int? heroOffset;

  const AssetViewer({super.key, required this.initialIndex, this.heroOffset});

  @override
  ConsumerState createState() => _AssetViewerState();

  static void setAsset(WidgetRef ref, BaseAsset asset) {
    ref.read(assetViewerProvider.notifier).reset();
    _setAsset(ref, asset);
  }

  static void _setAsset(WidgetRef ref, BaseAsset asset) {
    // Always holds the current asset from the timeline
    ref.read(assetViewerProvider.notifier).setAsset(asset);
    // The currentAssetNotifier actually holds the current asset that is displayed
    // which could be stack children as well
    ref.read(currentAssetNotifier.notifier).setAsset(asset);
    if (asset.isVideo || asset.isMotionPhoto) {
      ref.read(videoPlaybackValueProvider.notifier).reset();
      ref.read(videoPlayerControlsProvider.notifier).pause();
    }
    // Hide controls by default for videos
    if (asset.isVideo) ref.read(assetViewerProvider.notifier).setControls(false);
  }
}

enum _DragIntent { none, dismiss, scroll }

class _AssetViewerState extends ConsumerState<AssetViewer> with TickerProviderStateMixin {
  static final _snapSpring = SpringDescription.withDampingRatio(mass: 0.5, stiffness: 100.0, ratio: 1.1);
  static const _minFlingVelocity = 15.0;
  static const _minSnapDistance = 25.0;

  late PageController pageController;
  // PhotoViewGallery takes care of disposing its controllers
  PhotoViewControllerBase? viewController;
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _ballisticAnimController;

  StreamSubscription? reloadSubscription;
  StreamSubscription? _scaleBoundarySub;

  bool blockGestures = false;
  bool dragInProgress = false;
  bool shouldPopOnDrag = false;
  _DragIntent _dragIntent = _DragIntent.none;
  Offset _dragStartGlobalPosition = Offset.zero;
  Offset dragDownPosition = Offset.zero;
  late PhotoViewControllerValue initialPhotoViewState;

  double _snapOffset = 0.0;
  double _previousScrollOffset = 0.0;

  late final int heroOffset;
  bool assetReloadRequested = false;
  int totalAssets = 0;
  Map<String, GlobalKey> videoPlayerKeys = {};

  late final _AssetPreloader _preloader;
  KeepAliveLink? _stackChildrenKeepAlive;

  @override
  void initState() {
    super.initState();
    assert(ref.read(currentAssetNotifier) != null, "Current asset should not be null when opening the AssetViewer");
    pageController = PageController(initialPage: widget.initialIndex);
    _scrollController.addListener(_onScroll);
    _ballisticAnimController = AnimationController.unbounded(vsync: this)..addListener(_onBallisticTick);
    final timelineService = ref.read(timelineServiceProvider);
    totalAssets = timelineService.totalAssets;
    _preloader = _AssetPreloader(timelineService: timelineService, mounted: () => mounted);
    WidgetsBinding.instance.addPostFrameCallback(_onAssetInit);
    reloadSubscription = EventStream.shared.listen(_onEvent);
    heroOffset = widget.heroOffset ?? TabsRouterScope.of(context)?.controller.activeIndex ?? 0;
    final asset = ref.read(currentAssetNotifier);
    if (asset != null) _stackChildrenKeepAlive = ref.read(stackChildrenNotifier(asset).notifier).ref.keepAlive();
  }

  @override
  void dispose() {
    _ballisticAnimController.dispose();
    _scrollController.dispose();
    pageController.dispose();
    _preloader.dispose();
    reloadSubscription?.cancel();
    _scaleBoundarySub?.cancel();
    _stackChildrenKeepAlive?.close();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Tolerance get _scrollTolerance {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Tolerance(velocity: 1.0 / (0.05 * dpr), distance: 1.0 / dpr);
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    ref
        .read(assetViewerProvider.notifier)
        .updateShowingDetailsFromScroll(
          scrollingUp: offset > _previousScrollOffset,
          offset: offset,
          minOffset: 5,
          snapOffset: _snapOffset,
        );
    _previousScrollOffset = offset;
  }

  /// Drive the scroll controller by [dy] pixels (positive = scroll down).
  void _scrollBy(double dy) {
    if (!_scrollController.hasClients) return;
    final newOffset = (_scrollController.offset - dy).clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(newOffset);
  }

  /// Animate the scroll position to [target] using a spring simulation.
  void _animateScrollTo(double target, double velocity) {
    final offset = _scrollController.offset;
    final tolerance = _scrollTolerance;
    if ((offset - target).abs() < tolerance.distance) {
      _scrollController.jumpTo(target);
      return;
    }
    _ballisticAnimController.value = offset;
    _ballisticAnimController.animateWith(
      ScrollSpringSimulation(_snapSpring, offset, target, velocity, tolerance: tolerance),
    );
  }

  Simulation _createFlingSimulation(double offset, double velocity) {
    final tolerance = _scrollTolerance;
    return CurrentPlatform.isIOS
        ? BouncingScrollSimulation(
            position: offset,
            velocity: velocity,
            leadingExtent: _snapOffset,
            trailingExtent: _scrollController.position.maxScrollExtent,
            spring: _snapSpring,
            tolerance: tolerance,
          )
        : ClampingScrollSimulation(position: offset, velocity: velocity, tolerance: tolerance);
  }

  void _onBallisticTick() {
    if (!_scrollController.hasClients) return;
    final raw = _ballisticAnimController.value;
    final max = _scrollController.position.maxScrollExtent;
    final offset = raw.clamp(0.0, max);
    final prevOffset = _scrollController.offset;

    // Stop at bounds
    if (raw != offset) {
      _ballisticAnimController.stop();
      _scrollController.jumpTo(offset);
      return;
    }

    // During free-scroll deceleration when scrolling up, don't cross into
    // the snap zone. Stop at snapOffset so the user can release there cleanly.
    final snap = _snapOffset;
    if (prevOffset <= snap && offset > snap) {
      _ballisticAnimController.stop();
      _scrollController.jumpTo(snap);
      return;
    }

    _scrollController.jumpTo(offset);
  }

  void _snapScroll(double velocity) {
    if (!_scrollController.hasClients) return;

    final offset = _scrollController.offset;
    final snap = _snapOffset;
    if (snap <= 0) return;

    // Above snap offset: free scroll or spring back to snap
    if (offset >= snap) {
      if (velocity.abs() < _minFlingVelocity) return;
      if (velocity < -_minFlingVelocity) {
        _animateScrollTo(snap, velocity);
        return;
      }
      // Scrolling up: decelerate with platform-native physics
      _ballisticAnimController.value = offset;
      _ballisticAnimController.animateWith(_createFlingSimulation(offset, velocity));
      return;
    }

    // In snap zone (0 → snapOffset): snap to nearest target
    final double target;
    if (velocity.abs() > _minFlingVelocity) {
      target = velocity > 0 ? snap : 0;
    } else {
      target = (offset < _minSnapDistance) ? 0 : snap;
    }
    _animateScrollTo(target, velocity);
  }

  void _onDragStart(
    BuildContext context,
    DragStartDetails details,
    PhotoViewControllerBase controller,
    PhotoViewScaleStateController scaleStateController,
  ) {
    _ballisticAnimController.stop();
    viewController = controller;
    dragDownPosition = details.localPosition;
    _dragStartGlobalPosition = details.globalPosition;
    initialPhotoViewState = controller.value;
    final showingDetails = ref.read(assetViewerProvider).showingDetails;
    _dragIntent = showingDetails ? _DragIntent.scroll : _DragIntent.none;
    final isZoomed =
        scaleStateController.scaleState == PhotoViewScaleState.zoomedIn ||
        scaleStateController.scaleState == PhotoViewScaleState.covering;
    if (!showingDetails && isZoomed) blockGestures = true;
  }

  void _onDragUpdate(BuildContext context, DragUpdateDetails details, PhotoViewControllerValue controllerValue) {
    if (blockGestures) return;

    dragInProgress = true;

    if (_dragIntent == _DragIntent.none) {
      _dragIntent = switch ((details.globalPosition - _dragStartGlobalPosition).dy) {
        > 1 => _DragIntent.dismiss,
        < -1 => _DragIntent.scroll,
        _ => _DragIntent.none,
      };
    }

    switch (_dragIntent) {
      case _DragIntent.none:
        return;
      case _DragIntent.dismiss:
        _handleDragDown(context, details.localPosition - dragDownPosition);
        return;
      case _DragIntent.scroll:
        _scrollBy(details.delta.dy);
        return;
    }
  }

  void _onDragEnd(BuildContext context, DragEndDetails details, PhotoViewControllerValue controllerValue) {
    dragInProgress = false;

    final intent = _dragIntent;
    _dragIntent = _DragIntent.none;

    if (intent == _DragIntent.scroll) {
      _snapScroll(-details.velocity.pixelsPerSecond.dy);
      return;
    }

    if (shouldPopOnDrag) {
      context.maybePop();
      return;
    }

    if (blockGestures) {
      blockGestures = false;
      return;
    }

    viewController?.animateMultiple(
      position: initialPhotoViewState.position,
      scale: viewController?.initialScale ?? initialPhotoViewState.scale,
      rotation: initialPhotoViewState.rotation,
    );
    ref.read(assetViewerProvider.notifier).setOpacity(255);
  }

  void _handleDragDown(BuildContext context, Offset delta) {
    const dragRatio = 0.2;
    const popThreshold = 75.0;

    final distance = delta.distance;
    shouldPopOnDrag = delta.dy > 0 && distance > popThreshold;

    final maxScaleDistance = context.height * 0.5;
    final scaleReduction = (distance / maxScaleDistance).clamp(0.0, dragRatio);
    final initialScale = viewController?.initialScale ?? initialPhotoViewState.scale;
    final updatedScale = initialScale != null ? initialScale * (1.0 - scaleReduction) : null;

    final backgroundOpacity = (255 * (1.0 - (scaleReduction / dragRatio))).round();

    viewController?.updateMultiple(position: initialPhotoViewState.position + delta, scale: updatedScale);
    ref.read(assetViewerProvider.notifier).setOpacity(backgroundOpacity);
  }

  void _onTapUp(BuildContext context, TapUpDetails details, PhotoViewControllerValue controllerValue) {
    if (!ref.read(assetViewerProvider).showingDetails) ref.read(assetViewerProvider.notifier).toggleControls();
  }

  void _onLongPress(BuildContext context, LongPressStartDetails details, PhotoViewControllerValue controllerValue) =>
      ref.read(isPlayingMotionVideoProvider.notifier).playing = true;

  void _onScaleStateChanged(PhotoViewScaleState scaleState) {
    if (scaleState != PhotoViewScaleState.initial) {
      if (!dragInProgress) ref.read(assetViewerProvider.notifier).setControls(false);

      ref.read(videoPlayerControlsProvider.notifier).pause();
      return;
    }

    if (!ref.read(assetViewerProvider).showingDetails) ref.read(assetViewerProvider.notifier).setControls(true);
  }

  void _onAssetInit(Duration timeStamp) {
    _preloader.preload(widget.initialIndex, context.sizeData);
    _handleCasting();
  }

  void _onAssetChanged(int index) async {
    _ballisticAnimController.stop();
    final timelineService = ref.read(timelineServiceProvider);
    final asset = await timelineService.getAssetAsync(index);
    if (asset == null) return;

    AssetViewer._setAsset(ref, asset);
    _preloader.preload(index, context.sizeData);
    _handleCasting();
    _stackChildrenKeepAlive?.close();
    _stackChildrenKeepAlive = ref.read(stackChildrenNotifier(asset).notifier).ref.keepAlive();
  }

  void _handleCasting() {
    if (!ref.read(castProvider).isCasting) return;
    final asset = ref.read(currentAssetNotifier);
    if (asset == null) return;

    if (asset is RemoteAsset) {
      context.scaffoldMessenger.hideCurrentSnackBar();
      ref.read(castProvider.notifier).loadMedia(asset, false);
      return;
    }

    context.scaffoldMessenger.clearSnackBars();
    ref.read(castProvider.notifier).stop();
    context.scaffoldMessenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          "local_asset_cast_failed".tr(),
          style: context.textTheme.bodyLarge?.copyWith(color: context.primaryColor),
        ),
      ),
    );
  }

  void _onPageChanged(int index, PhotoViewControllerBase? controller) {
    _onAssetChanged(index);
    viewController = controller;
    _listenForScaleBoundaries(controller);
  }

  void _listenForScaleBoundaries(PhotoViewControllerBase? controller) {
    _scaleBoundarySub?.cancel();
    _scaleBoundarySub = null;
    if (controller == null || controller.scaleBoundaries != null) return;
    _scaleBoundarySub = controller.outputStateStream.listen((_) {
      if (controller.scaleBoundaries != null) {
        _scaleBoundarySub?.cancel();
        _scaleBoundarySub = null;
        if (mounted) setState(() {});
      }
    });
  }

  void _onEvent(Event event) {
    switch (event) {
      case TimelineReloadEvent():
        _onTimelineReloadEvent();
      case ViewerReloadAssetEvent():
        assetReloadRequested = true;
      case ViewerShowDetailsEvent():
        _showDetails();
    }
  }

  void _showDetails() {
    if (!_scrollController.hasClients || _snapOffset <= 0) return;
    _ballisticAnimController.stop();
    _animateScrollTo(_snapOffset, 0);
  }

  void _onTimelineReloadEvent() {
    final timelineService = ref.read(timelineServiceProvider);
    totalAssets = timelineService.totalAssets;

    if (totalAssets == 0) {
      context.maybePop();
      return;
    }

    var index = pageController.page?.round() ?? 0;
    final currentAsset = ref.read(currentAssetNotifier);
    if (currentAsset != null) {
      final newIndex = timelineService.getIndex(currentAsset.heroTag);
      if (newIndex != null && newIndex != index) {
        index = newIndex;
        pageController.jumpToPage(index);
      }
    }

    if (index >= totalAssets) {
      index = totalAssets - 1;
      pageController.jumpToPage(index);
    }

    if (assetReloadRequested) {
      assetReloadRequested = false;
      _onAssetReloadEvent(index);
    }
  }

  void _onAssetReloadEvent(int index) async {
    final timelineService = ref.read(timelineServiceProvider);

    final newAsset = await timelineService.getAssetAsync(index);
    if (newAsset == null) return;

    final currentAsset = ref.read(currentAssetNotifier);

    // Do not reload if the asset has not changed
    if (newAsset.heroTag == currentAsset?.heroTag) return;

    _onAssetChanged(index);
  }

  PhotoViewGalleryPageOptions _assetBuilder(BuildContext context, int index) {
    final timelineService = ref.read(timelineServiceProvider);
    final asset = timelineService.getAssetSafe(index);

    // If asset is not available in buffer, return a placeholder
    if (asset == null) {
      return PhotoViewGalleryPageOptions.customChild(
        heroAttributes: PhotoViewHeroAttributes(tag: 'loading_$index'),
        child: Container(
          width: context.width,
          height: context.height,
          color: Colors.black.withAlpha(ref.read(assetViewerProvider).backgroundOpacity),
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    BaseAsset displayAsset = asset;
    final stackChildren = ref.read(stackChildrenNotifier(asset)).valueOrNull;
    if (stackChildren != null && stackChildren.isNotEmpty) {
      displayAsset = stackChildren.elementAt(ref.read(assetViewerProvider).stackIndex);
    }

    final isPlayingMotionVideo = ref.read(isPlayingMotionVideoProvider);
    if (displayAsset.isImage && !isPlayingMotionVideo) return _imageBuilder(context, displayAsset);

    return _videoBuilder(context, displayAsset);
  }

  PhotoViewGalleryPageOptions _imageBuilder(BuildContext context, BaseAsset asset) {
    final size = context.sizeData;
    return PhotoViewGalleryPageOptions(
      key: ValueKey(asset.heroTag),
      imageProvider: getFullImageProvider(asset, size: size),
      heroAttributes: PhotoViewHeroAttributes(tag: '${asset.heroTag}_$heroOffset'),
      filterQuality: FilterQuality.high,
      tightMode: true,
      disableScaleGestures: ref.read(assetViewerProvider).showingDetails,
      onDragStart: _onDragStart,
      onDragUpdate: _onDragUpdate,
      onDragEnd: _onDragEnd,
      onTapUp: _onTapUp,
      onLongPressStart: asset.isMotionPhoto ? _onLongPress : null,
      errorBuilder: (_, __, ___) => Container(
        width: size.width,
        height: size.height,
        color: Colors.black.withAlpha(ref.read(assetViewerProvider).backgroundOpacity),
        child: Thumbnail.fromAsset(asset: asset, fit: BoxFit.contain),
      ),
    );
  }

  PhotoViewGalleryPageOptions _videoBuilder(BuildContext context, BaseAsset asset) {
    return PhotoViewGalleryPageOptions.customChild(
      onDragStart: _onDragStart,
      onDragUpdate: _onDragUpdate,
      onDragEnd: _onDragEnd,
      onTapUp: _onTapUp,
      heroAttributes: PhotoViewHeroAttributes(tag: '${asset.heroTag}_$heroOffset'),
      filterQuality: FilterQuality.high,
      maxScale: 1.0,
      basePosition: Alignment.center,
      disableScaleGestures: true,
      child: SizedBox(
        width: context.width,
        height: context.height,
        child: NativeVideoViewer(
          key: videoPlayerKeys.putIfAbsent(asset.heroTag, () => GlobalKey()),
          asset: asset,
          image: Image(
            key: ValueKey(asset),
            image: getFullImageProvider(asset, size: context.sizeData),
            fit: BoxFit.contain,
            height: context.height,
            width: context.width,
            alignment: Alignment.center,
          ),
        ),
      ),
    );
  }

  double _getImageHeight(double maxWidth, maxHeight) {
    final sb = viewController?.scaleBoundaries;
    if (sb != null) return sb.childSize.height * sb.initialScale;

    final asset = ref.read(currentAssetNotifier);
    if (asset == null || asset.width == null || asset.height == null) return maxHeight;

    final r = asset.width! / asset.height!;
    return math.min(maxWidth / r, maxHeight);
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild the widget when the asset viewer state changes
    // Using multiple selectors to avoid unnecessary rebuilds for other state changes
    final backgroundColor = Colors.black.withAlpha(ref.watch(assetViewerProvider.select((s) => s.backgroundOpacity)));
    ref.watch(assetViewerProvider.select((s) => s.stackIndex));
    ref.watch(isPlayingMotionVideoProvider);
    final showingControls = ref.watch(assetViewerProvider.select((s) => s.showingControls));
    final showingDetails = ref.watch(assetViewerProvider.select((s) => s.showingDetails));
    final padding = MediaQuery.paddingOf(context);

    // Listen for casting changes and send initial asset to the cast provider
    ref.listen(castProvider.select((value) => value.isCasting), (_, isCasting) {
      if (!isCasting) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleCasting();
      });
    });

    ref.listen(assetViewerProvider.select((value) => (value.showingControls, value.showingDetails)), (_, state) {
      final (controls, details) = state;
      final mode = !controls || (Platform.isIOS && details) ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge;
      unawaited(SystemChrome.setEnabledSystemUIMode(mode));
    });

    final viewportWidth = MediaQuery.widthOf(context);
    final viewportHeight = MediaQuery.heightOf(context);

    final imageHeight = _getImageHeight(viewportWidth, viewportHeight);

    final margin = (viewportHeight - imageHeight) / 2;
    final overflowBoxHeight = margin + imageHeight - (kMinInteractiveDimension / 2);
    _snapOffset = (margin + imageHeight) - (viewportHeight / 4);

    return PopScope(
      onPopInvokedWithResult: (didPop, result) => ref.read(currentAssetNotifier.notifier).dispose(),
      child: Scaffold(
        backgroundColor: backgroundColor,
        appBar: const ViewerTopAppBar(),
        extendBody: true,
        extendBodyBehindAppBar: true,
        floatingActionButton: IgnorePointer(
          ignoring: !showingControls,
          child: AnimatedOpacity(
            opacity: showingControls ? 1.0 : 0.0,
            duration: Durations.short2,
            child: const DownloadStatusFloatingButton(),
          ),
        ),
        body: Stack(
          children: [
            SingleChildScrollView(
              controller: _scrollController,
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedOverflowBox(
                    size: Size(double.infinity, overflowBoxHeight),
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      height: viewportHeight,
                      child: PhotoViewGallery.builder(
                        gaplessPlayback: true,
                        loadingBuilder: (context, progress, index) => const Center(child: ImmichLoadingIndicator()),
                        pageController: pageController,
                        scrollPhysics: CurrentPlatform.isIOS
                            ? const FastScrollPhysics() // Use bouncing physics for iOS
                            : const FastClampingScrollPhysics(), // Use heavy physics for Android
                        itemCount: totalAssets,
                        onPageChanged: _onPageChanged,
                        scaleStateChangedCallback: _onScaleStateChanged,
                        builder: _assetBuilder,
                        backgroundDecoration: BoxDecoration(color: backgroundColor),
                        enablePanAlways: true,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onVerticalDragStart: (_) => _ballisticAnimController.stop(),
                    onVerticalDragUpdate: (details) => _scrollBy(details.delta.dy),
                    onVerticalDragEnd: (details) => _snapScroll(-details.velocity.pixelsPerSecond.dy),
                    child: AnimatedOpacity(
                      opacity: showingDetails ? 1.0 : 0.0,
                      duration: kThemeAnimationDuration,
                      child: AbsorbPointer(
                        absorbing: !showingDetails,
                        child: AssetDetails(minHeight: _snapOffset + viewportHeight - overflowBoxHeight),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!Platform.isIOS)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AbsorbPointer(
                  absorbing: true,
                  child: AnimatedContainer(
                    duration: kThemeAnimationDuration,
                    color: Colors.black.withValues(alpha: showingDetails ? 0.6 : 0.0),
                    height: padding.top,
                  ),
                ),
              ),
            const Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [AssetStackRow(), ViewerBottomBar()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetPreloader {
  static final _dummyListener = ImageStreamListener((image, _) => image.dispose());

  final TimelineService timelineService;
  final bool Function() mounted;

  Timer? _timer;
  ImageStream? _prevStream;
  ImageStream? _nextStream;

  _AssetPreloader({required this.timelineService, required this.mounted});

  void preload(int index, Size size) {
    unawaited(timelineService.preloadAssets(index));
    _timer?.cancel();
    _timer = Timer(Durations.medium4, () async {
      if (!mounted()) return;
      final (prev, next) = await (
        timelineService.getAssetAsync(index - 1),
        timelineService.getAssetAsync(index + 1),
      ).wait;
      if (!mounted()) return;
      _prevStream?.removeListener(_dummyListener);
      _nextStream?.removeListener(_dummyListener);
      _prevStream = prev != null ? _resolveImage(prev, size) : null;
      _nextStream = next != null ? _resolveImage(next, size) : null;
    });
  }

  ImageStream _resolveImage(BaseAsset asset, Size size) {
    return getFullImageProvider(asset, size: size).resolve(ImageConfiguration.empty)..addListener(_dummyListener);
  }

  void dispose() {
    _timer?.cancel();
    _prevStream?.removeListener(_dummyListener);
    _nextStream?.removeListener(_dummyListener);
  }
}
