import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';

/// [RegionCropper] using the sidecar, which already has OpenCV loaded.
class SidecarRegionCropper implements RegionCropper {
  SidecarRegionCropper(this._client, this._configProvider);

  final SidecarClient _client;
  final AppConfig Function() _configProvider;

  @override
  Future<Map<String, String>> crop(
    ExamPage page,
    List<PageRegion> regions, {
    required Directory outputDirectory,
  }) async {
    if (!page.hasImage || regions.isEmpty) return const <String, String>{};
    final Map<String, Object?> response = await _client.post(
      'crop',
      <String, Object?>{
        'image_path': page.imagePath,
        'out_dir': outputDirectory.path,
        'max_dim': _configProvider().maxImageDimension,
        'padding': 0.008,
        'regions': <Map<String, Object?>>[
          for (final PageRegion region in regions)
            <String, Object?>{
              'region_id': region.regionId,
              'box': region.box.toJson(),
            },
        ],
      },
    );
    final JsonMap crops = readMap(response['crops']) ?? const <String, Object?>{};
    return <String, String>{
      for (final MapEntry<String, Object?> entry in crops.entries)
        if (readString(entry.value) case final String path) entry.key: path,
    };
  }
}
