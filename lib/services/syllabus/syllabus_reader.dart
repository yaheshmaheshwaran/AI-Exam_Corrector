import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/pdf_service.dart';

/// A slide whose content is a picture — a screenshot or scan of the syllabus
/// — so its text cannot be read from the file itself.
class PictureSlide {
  const PictureSlide({required this.slide, required this.bytes, required this.mimeType});

  final int slide;
  final Uint8List bytes;
  final String mimeType;
}

/// What was read from a syllabus file: its text, and any slides that are
/// pictures and need reading another way.
class SyllabusText {
  const SyllabusText(this.text, {this.pictureSlides = const <PictureSlide>[]});

  final String text;
  final List<PictureSlide> pictureSlides;
}

/// Reads a syllabus file as the college published it — a PDF with a text
/// layer, a PowerPoint deck, a Word document, or plain text — without
/// converting it, so nothing is lost to a conversion.
///
/// Tables in PowerPoint and Word come out one row per line with the cells
/// separated by tabs, so the parser can tell the unit column from the topics
/// column. Scanned PDFs are not read.
class SyllabusReader {
  const SyllabusReader({PdfService pdf = const PdfService()}) : _pdf = pdf;

  final PdfService _pdf;

  static const List<String> extensions = <String>['pdf', 'pptx', 'docx', 'txt', 'md'];

  /// The text alone.
  Future<String> read(String path) async => (await readDocument(path)).text;

  Future<SyllabusText> readDocument(String path) async {
    final String extension = path.split('.').last.toLowerCase();
    final SyllabusText read = switch (extension) {
      'pdf' => SyllabusText(await _fromPdf(path)),
      'pptx' => await _fromPptx(path),
      'docx' => SyllabusText(await _fromDocx(path)),
      'txt' || 'md' => SyllabusText(await _fromText(path)),
      'ppt' => throw const SyllabusException(
          'This is an older PowerPoint file (.ppt). Open it in PowerPoint and '
          'save it as .pptx (File › Save As), then add it again.',
        ),
      'doc' => throw const SyllabusException(
          'This is an older Word file (.doc). Open it in Word and save it as '
          '.docx (File › Save As), then add it again.',
        ),
      _ => throw SyllabusException(
          'A syllabus can be a PDF, a PowerPoint (.pptx), a Word document '
          '(.docx), or a text file (.txt, .md) — not ".$extension".',
        ),
    };
    if (read.text.trim().isEmpty && read.pictureSlides.isEmpty) {
      throw const SyllabusException('No text could be read from this syllabus file.');
    }
    return read;
  }

  Future<String> _fromPdf(String path) async {
    final String? text = await _pdf.extractTextIfPresent(path);
    if (text == null || text.trim().isEmpty) {
      throw const SyllabusException(
        'This PDF has no selectable text — it looks like a scan. Upload the '
        'syllabus as the PowerPoint or Word file it was made from, or a PDF '
        'with selectable text.',
      );
    }
    return text
        .split('\n')
        .where((String line) => !RegExp(r'^---\s*Page\s+\d+\s*---$').hasMatch(line.trim()))
        .join('\n');
  }

  Future<String> _fromText(String path) async {
    try {
      return await File(path).readAsString();
    } on FileSystemException catch (error) {
      throw SyllabusException('The syllabus file could not be read: ${error.message}.');
    }
  }

  Future<Archive> _zip(String path, String kind) async {
    try {
      return ZipDecoder().decodeBytes(await File(path).readAsBytes());
    } on FileSystemException catch (error) {
      throw SyllabusException('The syllabus file could not be read: ${error.message}.');
    } on Exception {
      throw SyllabusException('This does not look like a $kind file — it may be damaged.');
    }
  }

  static XmlDocument? _xml(Archive archive, String name) {
    final ArchiveFile? file = archive.findFile(name);
    if (file == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
    } on XmlException {
      return null;
    }
  }

  // --------------------------------------------------------------------------
  // Word
  // --------------------------------------------------------------------------

  /// A .docx is a zip whose `word/document.xml` holds the text.
  Future<String> _fromDocx(String path) async {
    final Archive archive = await _zip(path, 'Word (.docx)');
    final XmlDocument? document = _xml(archive, 'word/document.xml');
    if (document == null) {
      throw const SyllabusException('This Word file has no document text.');
    }
    return textOfDocumentXml(document);
  }

  /// A Word document's text in order: a line per paragraph, and a line per
  /// table row with its cells separated by tabs.
  static String textOfDocumentXml(XmlDocument xml) {
    final List<String> lines = <String>[];

    String paragraph(XmlElement p) {
      final StringBuffer line = StringBuffer();
      for (final XmlElement node in p.descendantElements) {
        switch (node.name.qualified) {
          case 'w:t':
            line.write(node.innerText);
          case 'w:tab':
            line.write('    ');
          case 'w:br':
            line.write('\n');
        }
      }
      return line.toString();
    }

    void visit(XmlElement element) {
      switch (element.name.qualified) {
        case 'w:p':
          lines.add(paragraph(element));
        case 'w:tbl':
          for (final XmlElement row in element.findElements('w:tr')) {
            lines.add(<String>[
              for (final XmlElement cell in row.findElements('w:tc'))
                cell
                    .findAllElements('w:p')
                    .map(paragraph)
                    .map((String t) => t.trim())
                    .where((String t) => t.isNotEmpty)
                    .join(' '),
            ].join('\t'));
          }
        default:
          element.childElements.forEach(visit);
      }
    }

    xml.rootElement.childElements.forEach(visit);
    return lines.join('\n');
  }

  // --------------------------------------------------------------------------
  // PowerPoint
  // --------------------------------------------------------------------------

  /// A .pptx is a zip of slides in XML. Slides are read in presentation
  /// order, hidden ones skipped; on each, the text boxes and tables are read
  /// top to bottom and left to right — the order a teacher reads them, not
  /// the order they were added.
  Future<SyllabusText> _fromPptx(String path) async {
    final Archive archive = await _zip(path, 'PowerPoint (.pptx)');
    final List<String> slides = slideOrder(archive);
    if (slides.isEmpty) {
      throw const SyllabusException('This PowerPoint file has no slides.');
    }

    final StringBuffer text = StringBuffer();
    final List<PictureSlide> pictures = <PictureSlide>[];
    int number = 0;
    for (final String name in slides) {
      final XmlDocument? slide = _xml(archive, name);
      if (slide == null) continue;
      number++;
      if (slide.rootElement.getAttribute('show') == '0') continue;

      final Map<String, String> links = _relationships(archive, name);
      final _Shape content = _group(slide.rootElement.findAllElements('p:spTree').firstOrNull, archive, links);
      text.writeln('--- Slide $number ---');
      for (final String line in content.lines) {
        text.writeln(line);
      }

      // Little text but a picture: the syllabus is in the picture.
      final int characters = content.lines.join().replaceAll(RegExp(r'\s'), '').length;
      if (content.pictures.isNotEmpty && characters < 80) {
        final ({Uint8List bytes, String mime}) largest = content.pictures
            .reduce((a, b) => a.bytes.length >= b.bytes.length ? a : b);
        pictures.add(PictureSlide(slide: number, bytes: largest.bytes, mimeType: largest.mime));
      }
    }
    return SyllabusText(text.toString(), pictureSlides: pictures);
  }

  /// The deck's slides in the order they are shown.
  static List<String> slideOrder(Archive archive) {
    final XmlDocument? presentation = _xml(archive, 'ppt/presentation.xml');
    final Map<String, String> links = _relationships(archive, 'ppt/presentation.xml');
    final List<String> ordered = <String>[
      if (presentation != null)
        for (final XmlElement id in presentation.findAllElements('p:sldId'))
          if (links[id.getAttribute('r:id') ?? ''] case final String target) target,
    ];
    if (ordered.isNotEmpty) return ordered;
    // No presentation part: fall back on the slides' own numbering.
    final List<String> found = <String>[
      for (final ArchiveFile file in archive.files)
        if (RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(file.name)) file.name,
    ]..sort((String a, String b) => _slideNumber(a).compareTo(_slideNumber(b)));
    return found;
  }

  static int _slideNumber(String name) =>
      int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(name)?.group(1) ?? '') ?? 0;

  /// A part's relationships, by ID, as full paths inside the zip.
  static Map<String, String> _relationships(Archive archive, String part) {
    final int slash = part.lastIndexOf('/');
    final String folder = part.substring(0, slash);
    final XmlDocument? rels = _xml(archive, '$folder/_rels/${part.substring(slash + 1)}.rels');
    if (rels == null) return const <String, String>{};
    return <String, String>{
      for (final XmlElement rel in rels.findAllElements('Relationship'))
        if (rel.getAttribute('Id') case final String id)
          id: _resolve(folder, rel.getAttribute('Target') ?? ''),
    };
  }

  static String _resolve(String folder, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final List<String> parts = folder.split('/');
    for (final String piece in target.split('/')) {
      if (piece == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (piece != '.') {
        parts.add(piece);
      }
    }
    return parts.join('/');
  }

  /// Shapes within this height of one another, in EMU (about 0.15 inch),
  /// are on the same row and read left to right.
  static const int _rowTolerance = 137160;

  /// A tree of shapes — a slide or a group — as one block of lines in
  /// reading order.
  static _Shape _group(XmlElement? tree, Archive archive, Map<String, String> links) {
    if (tree == null) return const _Shape();
    final List<_Shape> shapes = <_Shape>[];
    int index = 0;
    for (final XmlElement child in tree.childElements) {
      final _Shape? shape = switch (child.name.qualified) {
        'p:sp' => _text(child),
        'p:graphicFrame' => _frame(child, archive, links),
        'p:grpSp' => _group(child, archive, links).at(_offset(child)),
        'p:pic' => _picture(child, archive, links),
        _ => null,
      };
      if (shape != null) shapes.add(shape.withIndex(index++));
    }

    // Titles without a position of their own first; then by position; then
    // anything else without a position, in the order it was placed.
    int key(_Shape s) => s.y ?? (s.title ? -1 : (1 << 40) + s.index);
    shapes.sort((_Shape a, _Shape b) => key(a).compareTo(key(b)));
    final List<List<_Shape>> rows = <List<_Shape>>[];
    for (final _Shape shape in shapes) {
      final List<_Shape>? last = rows.isEmpty ? null : rows.last;
      if (last != null &&
          shape.y != null &&
          last.first.y != null &&
          (shape.y! - last.first.y!).abs() <= _rowTolerance) {
        last.add(shape);
      } else {
        rows.add(<_Shape>[shape]);
      }
    }
    final List<String> lines = <String>[];
    final List<({Uint8List bytes, String mime})> pictures = <({Uint8List bytes, String mime})>[];
    for (final List<_Shape> row in rows) {
      row.sort((_Shape a, _Shape b) => (a.x ?? 0).compareTo(b.x ?? 0));
      for (final _Shape shape in row) {
        lines.addAll(shape.lines);
        pictures.addAll(shape.pictures);
      }
    }
    return _Shape(lines: lines, pictures: pictures);
  }

  static ({int x, int y})? _offset(XmlElement shape) {
    final XmlElement? off = shape.findAllElements('a:off').firstOrNull;
    final int? x = int.tryParse(off?.getAttribute('x') ?? '');
    final int? y = int.tryParse(off?.getAttribute('y') ?? '');
    return x == null || y == null ? null : (x: x, y: y);
  }

  static _Shape _text(XmlElement shape) {
    final String? placeholder =
        shape.findAllElements('p:ph').firstOrNull?.getAttribute('type');
    final List<String> lines = <String>[
      for (final XmlElement p in shape.findAllElements('a:p'))
        if (_paragraph(p) case final String line when line.trim().isNotEmpty) line,
    ];
    final ({int x, int y})? at = _offset(shape);
    return _Shape(
      lines: lines,
      x: at?.x,
      y: at?.y,
      title: placeholder == 'title' || placeholder == 'ctrTitle',
    );
  }

  static String _paragraph(XmlElement p) {
    final StringBuffer line = StringBuffer();
    for (final XmlElement node in p.descendantElements) {
      switch (node.name.qualified) {
        case 'a:t':
          line.write(node.innerText);
        case 'a:br':
          line.write('\n');
      }
    }
    return line.toString();
  }

  /// A table — a row per line, cells separated by tabs — or SmartArt text.
  static _Shape? _frame(XmlElement frame, Archive archive, Map<String, String> links) {
    final ({int x, int y})? at = _offset(frame);
    final XmlElement? table = frame.findAllElements('a:tbl').firstOrNull;
    if (table != null) {
      return _Shape(
        x: at?.x,
        y: at?.y,
        lines: <String>[
          for (final XmlElement row in table.findElements('a:tr'))
            <String>[
              for (final XmlElement cell in row.findElements('a:tc'))
                cell
                    .findAllElements('a:p')
                    .map(_paragraph)
                    .map((String t) => t.trim())
                    .where((String t) => t.isNotEmpty)
                    .join(' '),
            ].join('\t'),
        ],
      );
    }
    // SmartArt keeps its text in a data part of its own.
    final String? data = frame.findAllElements('dgm:relIds').firstOrNull?.getAttribute('r:dm');
    final XmlDocument? diagram = data == null || links[data] == null ? null : _xml(archive, links[data]!);
    if (diagram == null) return null;
    return _Shape(
      x: at?.x,
      y: at?.y,
      lines: <String>[
        for (final XmlElement p in diagram.findAllElements('a:p'))
          if (_paragraph(p) case final String line when line.trim().isNotEmpty) line,
      ],
    );
  }

  static _Shape? _picture(XmlElement picture, Archive archive, Map<String, String> links) {
    final String? id = picture.findAllElements('a:blip').firstOrNull?.getAttribute('r:embed');
    final String? target = id == null ? null : links[id];
    if (target == null) return null;
    final String extension = target.split('.').last.toLowerCase();
    final String? mime = switch (extension) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      'webp' => 'image/webp',
      'tif' || 'tiff' => 'image/tiff',
      _ => null, // Vector drawings (emf, wmf, svg) are not pictures of text.
    };
    final ArchiveFile? file = archive.findFile(target);
    if (mime == null || file == null) return null;
    final ({int x, int y})? at = _offset(picture);
    return _Shape(
      x: at?.x,
      y: at?.y,
      pictures: <({Uint8List bytes, String mime})>[
        (bytes: Uint8List.fromList(file.content), mime: mime),
      ],
    );
  }
}

/// Something on a slide, with where it sits.
class _Shape {
  const _Shape({
    this.lines = const <String>[],
    this.pictures = const <({Uint8List bytes, String mime})>[],
    this.x,
    this.y,
    this.title = false,
    this.index = 0,
  });

  final List<String> lines;
  final List<({Uint8List bytes, String mime})> pictures;
  final int? x;
  final int? y;
  final bool title;
  final int index;

  _Shape at(({int x, int y})? offset) => _Shape(
        lines: lines,
        pictures: pictures,
        x: offset?.x,
        y: offset?.y,
        title: title,
        index: index,
      );

  _Shape withIndex(int i) =>
      _Shape(lines: lines, pictures: pictures, x: x, y: y, title: title, index: i);
}
