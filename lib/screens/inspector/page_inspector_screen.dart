import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/widgets/page_viewer.dart';

/// Developer view of page understanding.
///
/// Shows what every stage made of every page: each region's box, type,
/// reading order, confidence, which engine found it and which question it was
/// mapped to, and — for the selected region — every reading and every piece
/// of analysis behind it. This is where recognition quality gets improved:
/// a wrong mark usually traces back to something visible here.
class PageInspectorScreen extends StatefulWidget {
  const PageInspectorScreen({super.key, required this.assessment});

  final ExamAssessment assessment;

  static const String routeName = '/inspector';

  static Future<void> open(BuildContext context, ExamAssessment assessment) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: routeName),
        builder: (_) => PageInspectorScreen(assessment: assessment),
      ),
    );
  }

  @override
  State<PageInspectorScreen> createState() => _PageInspectorScreenState();
}

class _PageInspectorScreenState extends State<PageInspectorScreen> {
  int _pageIndex = 0;
  String? _selected;
  final Set<RegionType> _hidden = <RegionType>{};
  bool _showSegments = false;

  ExamAssessment get _assessment => widget.assessment;

  late final Map<String, List<String>> _questionsByRegion =
      _assessment.alignment.questionsByRegion;

  late final Map<String, String> _segmentByRegion = <String, String>{
    for (final AnswerSegment segment in _assessment.alignment.segments)
      for (final String id in segment.regionIds) id: segment.segmentId,
  };

  String _questionLabel(String regionId) {
    final String? parent = _assessment.region(regionId)?.parentRegionId;
    final List<String> ids = _questionsByRegion[regionId] ??
        (parent == null ? null : _questionsByRegion[parent]) ??
        const <String>[];
    if (ids.isEmpty) return '—';
    return ids
        .map((String id) => _assessment.questionPaper.byId(id)?.displayNumber ?? id)
        .map((String n) => 'Q$n')
        .join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<ExamPage> pages = _assessment.answerSheet.pages;
    final ExamPage page = pages[_pageIndex.clamp(0, pages.length - 1)];
    final List<PageRegion> visible = page.regions
        .where((PageRegion r) => !_hidden.contains(r.type))
        .toList()
      ..sort((PageRegion a, PageRegion b) => a.readingOrder.compareTo(b.readingOrder));

    return Scaffold(
      body: Column(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: const BoxDecoration(
              color: AppTheme.cardBackground,
              border: Border(bottom: BorderSide(color: AppTheme.stroke)),
            ),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Text('Page inspector', style: theme.textTheme.titleMedium),
                const SizedBox(width: 16),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        for (final RegionType type in RegionType.values)
                          if (_assessment.answerSheet.countOf(type) > 0)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: FilterChip(
                                visualDensity: VisualDensity.compact,
                                selected: !_hidden.contains(type),
                                avatar: Container(width: 8, height: 8, color: regionColor(type)),
                                label: Text(
                                  '${type.displayName} (${_assessment.answerSheet.countOf(type)})',
                                  style: const TextStyle(fontSize: 11.5),
                                ),
                                onSelected: (bool on) => setState(() {
                                  on ? _hidden.remove(type) : _hidden.add(type);
                                }),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  children: <Widget>[
                    Switch(
                      value: _showSegments,
                      onChanged: (bool v) => setState(() => _showSegments = v),
                    ),
                    const Text('Answer boundaries', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: 190,
                  child: ListView.builder(
                    itemCount: pages.length,
                    itemBuilder: (BuildContext context, int index) {
                      final ExamPage p = pages[index];
                      return ListTile(
                        dense: true,
                        selected: index == _pageIndex,
                        title: Text('Page ${p.pageNumber}'),
                        subtitle: Text(
                          p.isBlank
                              ? 'blank — skipped'
                              : '${p.regions.length} regions · ${p.detector.split(':').first}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () => setState(() {
                          _pageIndex = index;
                          _selected = null;
                        }),
                      );
                    },
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: PageViewer(
                      page: page,
                      regions: visible,
                      selectedRegionId: _selected,
                      captionFor: (PageRegion r) => _showSegments
                          ? '${_segmentByRegion[r.regionId] ?? 'none'} · ${_questionLabel(r.regionId)}'
                          : '#${r.readingOrder + 1} ${r.type.wireName} ${_questionLabel(r.regionId)}',
                      onTapRegion: (PageRegion r) => setState(() => _selected = r.regionId),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 360,
                  child: _selected == null
                      ? _PageSummary(page: page, assessment: _assessment)
                      : _RegionDetails(
                          assessment: _assessment,
                          region: _assessment.region(_selected!)!,
                          question: _questionLabel(_selected!),
                          segment: _segmentByRegion[_selected!],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PageSummary extends StatelessWidget {
  const _PageSummary({required this.page, required this.assessment});

  final ExamPage page;
  final ExamAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<RegionType, int> counts = <RegionType, int>{};
    for (final PageRegion region in page.regions) {
      counts[region.type] = (counts[region.type] ?? 0) + 1;
    }
    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        Text('Page ${page.pageNumber}', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _Field('Size', '${page.width} × ${page.height} px${page.dpi > 0 ? ' at ${page.dpi} dpi' : ''}'),
        _Field('Text layer', page.hasTextLayer ? 'yes' : 'no'),
        _Field('Ink coverage', '${(page.inkCoverage * 100).toStringAsFixed(2)}%'),
        _Field('Blank', page.isBlank ? 'yes — skipped by every later stage' : 'no'),
        _Field('Detector', page.detector.isEmpty ? '—' : page.detector),
        _Field('Image', page.imagePath ?? 'none'),
        const SizedBox(height: 10),
        Text('Regions', style: theme.textTheme.titleSmall),
        for (final MapEntry<RegionType, int> entry in counts.entries)
          Text('${entry.key.displayName}: ${entry.value}', style: theme.textTheme.bodySmall),
        const SizedBox(height: 10),
        Text('Tap a region to inspect it.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
        if (assessment.alignment.unassignedRegionIds.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            '${assessment.alignment.unassignedRegionIds.length} region(s) across the '
            'paper were not assigned to any question.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.caution),
          ),
        ],
      ],
    );
  }
}

class _RegionDetails extends StatelessWidget {
  const _RegionDetails({
    required this.assessment,
    required this.region,
    required this.question,
    required this.segment,
  });

  final ExamAssessment assessment;
  final PageRegion region;
  final String question;
  final String? segment;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HandwritingEvidence? handwriting = assessment.evidence.handwriting[region.regionId];
    final VisualEvidence? visual = assessment.evidence.visuals[region.regionId];

    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(width: 10, height: 10, color: regionColor(region.type)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Region ${region.readingOrder + 1}', style: theme.textTheme.titleMedium),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Field('ID', region.regionId),
        _Field('Type', region.type.wireName),
        _Field('Confidence', region.confidence.toStringAsFixed(2)),
        _Field('Found by', region.origin.name),
        _Field('Reading order', '${region.readingOrder + 1}'),
        _Field('Question', question),
        _Field('Answer segment', segment ?? 'none'),
        if (region.parentRegionId != null) _Field('Parent', region.parentRegionId!),
        if (region.detectedLabel != null) _Field('Label seen', region.detectedLabel!),
        _Field(
          'Box',
          '${region.box.x.toStringAsFixed(3)}, ${region.box.y.toStringAsFixed(3)}, '
              '${region.box.width.toStringAsFixed(3)} × ${region.box.height.toStringAsFixed(3)}',
        ),
        if (handwriting != null) ...<Widget>[
          const Divider(height: 24),
          Text('Readings', style: theme.textTheme.titleSmall),
          if (handwriting.agreement != null)
            _Field('Agreement', handwriting.agreement!.toStringAsFixed(2)),
          if (handwriting.teacherText != null) _Field('Teacher', handwriting.teacherText!),
          if (handwriting.error != null) _Field('Error', handwriting.error!),
          for (int i = 0; i < handwriting.readings.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${handwriting.readings[i].source.label}'
                    '${i == handwriting.primaryIndex ? ' (primary)' : ''} · '
                    '${handwriting.readings[i].confidence.toStringAsFixed(2)}'
                    '${handwriting.readings[i].engine.isEmpty ? '' : ' · ${handwriting.readings[i].engine}'}',
                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  SelectableText(handwriting.readings[i].text, style: theme.textTheme.bodySmall),
                  for (final RecognizedLine line in handwriting.readings[i].lines)
                    Text(
                      '  ${line.confidence.toStringAsFixed(2)}  ${line.text}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        fontFamily: 'Consolas',
                        fontSize: 11,
                      ),
                    ),
                  if (handwriting.readings[i].uncertainSpans.isNotEmpty)
                    Text(
                      'Uncertain: ${handwriting.readings[i].uncertainSpans.map((UncertainSpan s) => '${s.text} (${s.confidence.toStringAsFixed(2)})').join(', ')}',
                      style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.caution),
                    ),
                ],
              ),
            ),
        ],
        if (visual != null) ...<Widget>[
          const Divider(height: 24),
          Text('Visual analysis', style: theme.textTheme.titleSmall),
          _Field('Status', visual.status.name),
          _Field('Confidence', visual.confidence.toStringAsFixed(2)),
          if (visual.error != null) _Field('Error', visual.error!),
          SelectableText(
            visual.toJson().entries
                .where((MapEntry<String, Object?> e) =>
                    !<String>{'regionId', 'kind', 'status', 'confidence', 'error'}.contains(e.key))
                .map((MapEntry<String, Object?> e) => '${e.key}: ${e.value}')
                .join('\n'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 104,
            child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}
