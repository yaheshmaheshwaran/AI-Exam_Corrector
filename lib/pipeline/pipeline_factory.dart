import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/pipeline/alignment/label_boundary_detector.dart';
import 'package:exam_corrector/pipeline/alignment/paper_question_aligner.dart';
import 'package:exam_corrector/pipeline/cache/artifact_store.dart';
import 'package:exam_corrector/pipeline/document/page_analyzer.dart';
import 'package:exam_corrector/pipeline/document/pdf_text_layer_reader.dart';
import 'package:exam_corrector/pipeline/document/sidecar_document_renderer.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/exam_pipeline.dart';
import 'package:exam_corrector/pipeline/layout/hybrid_region_detector.dart';
import 'package:exam_corrector/pipeline/layout/local_region_detector.dart';
import 'package:exam_corrector/pipeline/layout/sidecar_region_cropper.dart';
import 'package:exam_corrector/pipeline/layout/text_layer_region_detector.dart';
import 'package:exam_corrector/pipeline/layout/vision_region_detector.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key_reader.dart';
import 'package:exam_corrector/pipeline/marking/model_marking_engine.dart';
import 'package:exam_corrector/pipeline/questions/model_question_paper_extractor.dart';
import 'package:exam_corrector/pipeline/questions/question_paper_parser.dart';
import 'package:exam_corrector/pipeline/recognition/ensemble_handwriting_recognizer.dart';
import 'package:exam_corrector/pipeline/recognition/trocr_region_recognizer.dart';
import 'package:exam_corrector/pipeline/recognition/vision_handwriting_recognizer.dart';
import 'package:exam_corrector/pipeline/visual/vision_visual_analyzer.dart';
import 'package:exam_corrector/pipeline/visual/visual_evidence_engine.dart';
import 'package:exam_corrector/services/ai/model_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';
import 'package:exam_corrector/services/settings_store.dart';

/// Assembles the pipeline from configuration.
///
/// This is the one place that decides which implementation serves each
/// engine: the sidecar or nothing for local work, the configured model client
/// for everything a model does, and the layout engine the teacher chose.
/// Built afresh for each correction, so a change in Settings applies to the
/// next one without a restart.
class PipelineFactory {
  PipelineFactory({
    required this.config,
    required this.sidecar,
    required this.models,
    ArtifactStore? store,
  }) : _store = store;

  final AppConfig Function() config;
  final SidecarClient sidecar;
  final ModelClient models;
  final ArtifactStore? _store;

  /// The cache, under the application's per-user folder.
  ArtifactStore get store {
    final ArtifactStore? injected = _store;
    if (injected != null) return injected;
    final Directory root = SettingsStore.supportDirectory() ?? Directory.systemTemp;
    return ArtifactStore(
      Directory('${root.path}${Platform.pathSeparator}cache'),
      enabled: config().cacheEnabled,
    );
  }

  /// [marker] replaces the marking engine — tools use it to stop short of
  /// marking and spend no quota.
  ExamPipeline build({MarkingEngine? marker}) {
    final AppConfig current = config();

    final LocalRegionDetector local = LocalRegionDetector(sidecar);
    final VisionRegionDetector vision = VisionRegionDetector(models, config);
    final RegionDetector detector = switch (current.layoutEngine) {
      LayoutEngine.local => HybridRegionDetector(local: local, vision: null),
      LayoutEngine.vision => HybridRegionDetector(local: null, vision: vision),
      LayoutEngine.hybrid => HybridRegionDetector(local: local, vision: vision),
    };

    final VisionHandwritingRecognizer visionReader =
        VisionHandwritingRecognizer(models, config);
    final HandwritingRecognizer recognizer = EnsembleHandwritingRecognizer(
      local: current.ocrEnabled ? TrocrRegionRecognizer(sidecar, config) : null,
      vision: visionReader,
      configProvider: config,
      visionAvailable: () => models.isAvailable,
    );

    final VisionVisualAnalyzer visual = VisionVisualAnalyzer(models, config);
    final VisualEvidenceEngine visuals = models.isAvailable
        ? VisualEvidenceEngine(
            diagrams: visual,
            graphs: visual,
            tables: visual,
            equations: visual,
          )
        : const VisualEvidenceEngine();

    return ExamPipeline(
      config: config,
      store: store,
      renderer: SidecarDocumentRenderer(sidecar, config),
      textLayer: const PdfTextLayerReader(),
      pageAnalyzer: const DefaultPageAnalyzer(),
      regionDetector: detector,
      textLayerDetector: const TextLayerRegionDetector(PdfTextLayerReader()),
      cropper: SidecarRegionCropper(sidecar, config),
      recognizer: recognizer,
      visuals: visuals,
      visualFingerprint: models.isAvailable ? visual.fingerprint : 'none',
      questionExtractor: CompositeQuestionPaperExtractor(
        parser: const HeuristicQuestionPaperParser(),
        model: ModelQuestionPaperExtractor(models, config),
      ),
      boundaries: const LabelBoundaryDetector(),
      aligner: const PaperQuestionAligner(),
      marker: marker ?? ModelMarkingEngine(models, config),
      // A stand-in marker spends no quota, so neither does the key.
      answerKeys: marker == null && models.isAvailable ? ModelAnswerKeyEngine(models, config) : null,
      // The teacher's own key is read locally first; the model only helps
      // match one that follows no pattern.
      teacherKeys: CompositeTeacherKeyReader(
        model: marker == null && models.isAvailable ? ModelTeacherKeyReader(models, config) : null,
      ),
    );
  }
}
