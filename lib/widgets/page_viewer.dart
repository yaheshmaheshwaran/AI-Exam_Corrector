import 'dart:io';

import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/app_dialog.dart';

import 'package:exam_corrector/widgets/ui/skeleton.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';

/// One colour per region type, shared by every view that draws regions, so a
/// diagram is the same green in the evidence dialog and in the inspector.
Color regionColor(RegionType type) => switch (type) {
      RegionType.printedText => AppColors.regionPrinted,
      RegionType.questionNumber => AppColors.regionQuestionNumber,
      RegionType.handwrittenAnswer => AppColors.regionHandwriting,
      RegionType.diagram => AppColors.regionDiagram,
      RegionType.graph => AppColors.regionGraph,
      RegionType.table => AppColors.regionTable,
      RegionType.equation => AppColors.regionEquation,
      RegionType.label => AppColors.regionLabel,
      RegionType.crossedOut => AppColors.regionCrossedOut,
      RegionType.marginNote => AppColors.regionMarginNote,
      RegionType.header || RegionType.footer => AppColors.regionHeader,
      RegionType.unknown => AppColors.regionUnknown,
    };

/// While a page image decodes, a skeleton holds its place; then the page
/// fades in. An image already in memory appears at once.
Widget _fadeIn(BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) {
  if (wasSynchronouslyLoaded) return child;
  return Stack(
    fit: StackFit.passthrough,
    children: <Widget>[
      if (frame == null) const Positioned.fill(child: SkeletonImage()),
      AnimatedOpacity(
        opacity: frame == null ? 0 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: child,
      ),
    ],
  );
}

/// A page as it was scanned, with regions drawn over it.
///
/// The original image is always the thing shown: regions are an overlay on
/// the student's ink, never a replacement for it. Pages load at display
/// resolution, not scan resolution — a 300 dpi page decoded in full is tens of
/// megabytes, and a long script would exhaust memory.
class PageViewer extends StatelessWidget {
  const PageViewer({
    super.key,
    required this.page,
    this.regions = const <PageRegion>[],
    this.highlightRegionId,
    this.selectedRegionId,
    this.captionFor,
    this.onTapRegion,
    this.highlightBoxes = const <NormalizedBox>[],
  });

  final ExamPage page;

  /// The regions to draw. Empty draws none.
  final List<PageRegion> regions;

  /// Drawn prominently, with the rest faded.
  final String? highlightRegionId;

  /// Drawn with a heavier outline, as the inspector's selection.
  final String? selectedRegionId;

  /// A short caption drawn at a region's corner — its order, type, question.
  final String? Function(PageRegion region)? captionFor;

  final ValueChanged<PageRegion>? onTapRegion;

  /// Extra boxes to mark, such as uncertain words.
  final List<NormalizedBox> highlightBoxes;

  @override
  Widget build(BuildContext context) {
    final double aspect = page.width > 0 && page.height > 0
        ? page.width / page.height
        : 1 / 1.414;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 600;
        final double height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : width / aspect;
        final double fitWidth =
            width / height > aspect ? height * aspect : width;
        final Size size = Size(fitWidth, fitWidth / aspect);

        return InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: SizedBox.fromSize(
              size: size,
              child: GestureDetector(
                onTapUp: onTapRegion == null
                    ? null
                    : (TapUpDetails details) => _tap(details.localPosition, size),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        // The scan is paper: white in either theme.
                        color: Colors.white,
                        border: Border.all(color: context.colors.border),
                      ),
                      child: page.hasImage
                          ? Image.file(
                              File(page.imagePath!),
                              fit: BoxFit.fill,
                              cacheWidth: 1600,
                              gaplessPlayback: true,
                              frameBuilder: _fadeIn,
                              errorBuilder: (_, _, _) => const _MissingImage(),
                            )
                          : const _MissingImage(),
                    ),
                    CustomPaint(
                      painter: _RegionPainter(
                        regions: regions,
                        highlight: highlightRegionId,
                        selected: selectedRegionId,
                        captionFor: captionFor,
                        extra: highlightBoxes,
                        showText: !page.hasImage,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _tap(Offset position, Size size) {
    final double x = position.dx / size.width;
    final double y = position.dy / size.height;
    PageRegion? best;
    for (final PageRegion region in regions) {
      final NormalizedBox box = region.box;
      if (x < box.x || x > box.right || y < box.y || y > box.bottom) continue;
      if (best == null || box.area < best.box.area) best = region;
    }
    if (best != null) onTapRegion?.call(best);
  }
}

class _MissingImage extends StatelessWidget {
  const _MissingImage();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Page image unavailable — regions are shown at their positions.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.colors.textFaint, fontSize: 12),
        ),
      ),
    );
  }
}

class _RegionPainter extends CustomPainter {
  _RegionPainter({
    required this.regions,
    required this.highlight,
    required this.selected,
    required this.captionFor,
    required this.extra,
    required this.showText,
  });

  final List<PageRegion> regions;
  final String? highlight;
  final String? selected;
  final String? Function(PageRegion region)? captionFor;
  final List<NormalizedBox> extra;
  final bool showText;

  Rect _rect(NormalizedBox box, Size size) => Rect.fromLTWH(
        box.x * size.width,
        box.y * size.height,
        box.width * size.width,
        box.height * size.height,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final bool focused = highlight != null;

    for (final PageRegion region in regions) {
      final bool isHighlight = region.regionId == highlight;
      final bool isSelected = region.regionId == selected;
      final Color colour = regionColor(region.type);
      final Rect rect = _rect(region.box, size);

      if (isHighlight) {
        canvas.drawRect(
          rect.inflate(3),
          Paint()..color = AppColors.regionHandwriting.withValues(alpha: 0.12),
        );
      }
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isHighlight || isSelected ? 2.5 : 1.2
          ..color = focused && !isHighlight
              ? colour.withValues(alpha: 0.25)
              : colour.withValues(alpha: isSelected ? 1 : 0.85),
      );

      if (showText && (region.detectedText?.isNotEmpty ?? false)) {
        _text(
          canvas,
          region.detectedText!.split('\n').first,
          rect.topLeft + const Offset(2, 1),
          maxWidth: rect.width - 4,
          colour: AppColors.regionPrinted,
          fontSize: (rect.height * 0.6).clamp(5, 11).toDouble(),
        );
      }

      final String? caption = captionFor?.call(region);
      if (caption != null && (!focused || isHighlight)) {
        _label(canvas, caption, rect, colour);
      }
    }

    final Paint mark = Paint()..color = AppColors.regionMark;
    for (final NormalizedBox box in extra) {
      canvas.drawRect(_rect(box, size), mark);
    }
  }

  void _label(Canvas canvas, String caption, Rect rect, Color colour) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: caption,
        style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final Rect tag = Rect.fromLTWH(
      rect.left,
      (rect.top - painter.height - 2).clamp(0, double.infinity),
      painter.width + 6,
      painter.height + 2,
    );
    canvas.drawRect(tag, Paint()..color = colour);
    painter.paint(canvas, tag.topLeft + const Offset(3, 1));
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    required double maxWidth,
    required Color colour,
    required double fontSize,
  }) {
    if (maxWidth <= 0) return;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: colour, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_RegionPainter old) =>
      old.regions != regions ||
      old.highlight != highlight ||
      old.selected != selected ||
      old.extra != extra;
}

/// Shows a page with one region highlighted: where a piece of evidence came
/// from, on the student's actual paper.
Future<void> showRegionOnPage(
  BuildContext context, {
  required ExamPage page,
  required PageRegion region,
  List<NormalizedBox> marks = const <NormalizedBox>[],
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext context) {
      final Size screen = MediaQuery.sizeOf(context);
      return Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: screen.width * 0.8,
          height: screen.height * 0.88,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.crop_free, size: 16, color: regionColor(region.type)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Page ${page.pageNumber} → Region ${region.readingOrder + 1} '
                        '(${region.type.displayName.toLowerCase()})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      'Scroll or pinch to zoom',
                      style: context.text.caption,
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: PageViewer(
                    page: page,
                    regions: page.regions,
                    highlightRegionId: region.regionId,
                    highlightBoxes: marks,
                    captionFor: (PageRegion r) =>
                        r.regionId == region.regionId ? 'Region ${r.readingOrder + 1}' : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
