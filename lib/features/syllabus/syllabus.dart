import 'dart:async';
import 'dart:io';


import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/marking/exam/syllabus/syllabus_matcher.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/services/syllabus/syllabus_reader.dart';
import 'package:exam_corrector/state/marked_script.dart';
import 'package:exam_corrector/features/workspace.dart';

/// The teacher's saved syllabi, and which one the chosen paper is marked
/// against.
mixin SyllabusFeature on Workspace {
  /// What automatic matching found in the paper's text when it was chosen.
  SyllabusMatch? syllabusMatch;

  /// Bumped whenever the teacher chooses a syllabus, so a read of the saved
  /// choice that began before it never overwrites what they just chose.
  int _syllabusVersion = 0;

  /// Whether the syllabus library is available at all.
  bool get hasSyllabusLibrary => syllabusStore != null;

  bool _addingSyllabus = false;
  CancellationToken? _syllabusCancel;

  /// Stops reading syllabus files; those already saved are kept.
  void cancelSyllabusReading() {
    final CancellationToken? token = _syllabusCancel;
    if (token == null) return;
    setStatus('Stopping…');
    token.cancel();
  }

  /// Syllabus files are being read right now.
  bool get isAddingSyllabus => _addingSyllabus;

  /// Every saved syllabus.
  List<Syllabus> get syllabi => savedSyllabi;

  /// The teacher's choice for the chosen paper, or null for automatic.
  String? get syllabusChoice => chosenSyllabus;

  /// The syllabus the chosen paper is — or will be — marked against, and how
  /// it was chosen; null when there is none.
  ({String name, String how})? get syllabusInUse {
    if (chosenSyllabus == SyllabusLibrary.none) return null;
    if (chosenSyllabus case final String id) {
      for (final Syllabus syllabus in savedSyllabi) {
        if (syllabus.id == id) return (name: syllabus.name, how: 'chosen by you');
      }
    }
    if (assessment?.syllabus case final ({String id, String name, String how}) used) {
      return (name: used.name, how: used.how);
    }
    if (syllabusMatch case final SyllabusMatch match) {
      return (name: match.syllabus.name, how: 'matched by ${match.reason}');
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // Syllabi
  // --------------------------------------------------------------------------

  Future<void> reloadSyllabi() async {
    final SyllabusLibrary? library = syllabusStore;
    if (library == null) return;
    try {
      savedSyllabi = await library.list();
    } on IOException {
      savedSyllabi = const <Syllabus>[];
    }
    final SelectedDocument? paper = chosenPaper;
    if (paper != null) await prepareSyllabus(paper);
    notifyListeners();
  }

  /// Reads the teacher's choice for [paper], and matches the saved syllabi
  /// against its text so the card can say which one will be used.
  @override
  Future<void> prepareSyllabus(SelectedDocument paper) async {
    final SyllabusLibrary? library = syllabusStore;
    if (library == null) return;
    final int version = _syllabusVersion;
    bool current() => version == _syllabusVersion && chosenPaper == paper;

    String? choice;
    try {
      choice = await library.choiceFor(paper.contentHash);
    } on IOException {
      choice = null;
    }
    if (!current()) return;
    chosenSyllabus = choice;
    syllabusMatch = null;
    if (savedSyllabi.isEmpty) return;
    try {
      final String? text = await pdfReader.extractTextIfPresent(paper.filePath);
      if (text != null && current()) {
        final String opening = text.length > 6000 ? text.substring(0, 6000) : text;
        syllabusMatch = const SyllabusMatcher().best(savedSyllabi, title: '', text: opening);
      }
    } on AppException {
      // A scanned paper: it is matched once its questions have been read.
    }
  }

  /// Adds a syllabus to the library from a file the teacher picks.
  Future<Syllabus?> addSyllabus() async {
    if (syllabusStore == null || isBusy) return null;
    final String? path = await picker.pickSyllabus();
    if (path == null) return null;
    final List<Syllabus> added = await addSyllabusFiles(<String>[path]);
    return added.isEmpty ? null : added.single;
  }

  /// Adds syllabi from files dropped on the library or picked: each read and
  /// saved on its own, so one bad file does not stop the rest.
  Future<List<Syllabus>> addSyllabusFiles(List<String> paths) async {
    final SyllabusLibrary? library = syllabusStore;
    if (library == null || isBusy || paths.isEmpty) return const <Syllabus>[];

    final List<Syllabus> added = <Syllabus>[];
    final List<String> failures = <String>[];
    String name(String path) => path.split(RegExp(r'[/\\]')).last;

    choosing = true;
    _addingSyllabus = true;
    final CancellationToken token = CancellationToken();
    _syllabusCancel = token;
    bool cancelled = false;
    try {
      for (int i = 0; i < paths.length; i++) {
        final String path = paths[i];
        final String extension = path.contains('.') ? path.split('.').last.toLowerCase() : '';
        if (!SyllabusReader.extensions.contains(extension)) {
          failures.add('${name(path)}: not a PDF, PowerPoint (.pptx), Word (.docx) or text file.');
          continue;
        }
        setStatus(paths.length == 1
            ? 'Reading the syllabus…'
            : 'Reading syllabus ${i + 1} of ${paths.length}: ${name(path)}…');
        try {
          added.addAll(await library.add(
            path,
            cancel: token,
            onProgress: (String message) => setStatus(paths.length == 1
                ? message
                : '(${i + 1} of ${paths.length}) $message'),
          ));
        } on CancelledException {
          cancelled = true;
          break;
        } on AppException catch (error) {
          failures.add(paths.length == 1 ? error.message : '${name(path)}: ${error.message}');
        } on IOException catch (error) {
          failures.add('${name(path)}: could not be saved ($error).');
        }
      }
      await reloadSyllabi();

      final int files = added.map((Syllabus s) => s.sourceId).toSet().length;
      final String saved = added.length == 1
          ? 'Syllabus saved: ${added.single.name} — ${added.single.units.length} '
              'unit${added.single.units.length == 1 ? '' : 's'}.'
          : files == 1
              ? '${added.length} courses read from ${added.first.fileName} and saved.'
              : '${added.length} syllabi saved from $files files.';
      if (cancelled) {
        setStatus(added.isEmpty
            ? 'Stopped reading the syllabus.'
            : 'Stopped. $saved');
      } else if (failures.isEmpty) {
        // What could not be read — picture slides with no key — is said.
        final Set<String> notes = <String>{for (final Syllabus s in added) ...s.notes};
        setStatus(notes.isEmpty ? saved : '$saved ${notes.join(' ')}');
      } else {
        fail(
          added.isEmpty
              ? (paths.length == 1
                  ? 'The syllabus could not be read.'
                  : 'None of the ${paths.length} files could be read as a syllabus.')
              : '$saved ${failures.length} could not be read.',
          failures.join('\n'),
        );
      }
      return added;
    } finally {
      choosing = false;
      _addingSyllabus = false;
      _syllabusCancel = null;
      notifyListeners();
    }
  }

  /// Removes every course read from one uploaded file.
  Future<void> removeSyllabusFile(String sourceId) async {
    final SyllabusLibrary? library = syllabusStore;
    if (library == null || isBusy) return;
    try {
      await library.removeSource(sourceId);
    } on IOException catch (error) {
      fail('The syllabus file could not be removed.', '$error');
      return;
    }
    await reloadSyllabi();
    setStatus('Syllabus file removed.');
  }

  Future<void> removeSyllabus(String id) async {
    final SyllabusLibrary? library = syllabusStore;
    if (library == null || isBusy) return;
    try {
      await library.remove(id);
    } on IOException catch (error) {
      fail('The syllabus could not be removed.', '$error');
      return;
    }
    await reloadSyllabi();
    setStatus('Syllabus removed.');
  }

  /// Corrects a syllabus's course title or code — what matching relies on.
  Future<void> updateSyllabus(String id, {String? courseTitle, String? courseCode}) async {
    final SyllabusLibrary? library = syllabusStore;
    if (library == null) return;
    try {
      await library.update(id, courseTitle: courseTitle, courseCode: courseCode);
    } on IOException catch (error) {
      fail('The syllabus could not be saved.', '$error');
      return;
    }
    await reloadSyllabi();
  }

  /// Chooses the syllabus for the chosen paper: an ID, [SyllabusLibrary.none],
  /// or null to match automatically. Saved for the paper; applied at the next
  /// marking, which re-marks only the questions whose syllabus changed.
  Future<void> chooseSyllabus(String? choice) async {
    final SyllabusLibrary? library = syllabusStore;
    final SelectedDocument? paper = chosenPaper;
    if (library == null || paper == null || isBusy) return;
    _syllabusVersion++;
    chosenSyllabus = choice;
    try {
      await library.setChoice(paper.contentHash, choice);
    } on IOException catch (error) {
      fail('The choice could not be saved.', '$error');
      return;
    }
    final bool marked = scriptList.any((MarkedScript s) => s.result != null);
    for (final MarkedScript script in scriptList) {
      if (script.result != null) script.correctionsPending = true;
    }
    setStatus(<String>[
      switch (choice) {
        null => 'The syllabus will be matched automatically.',
        SyllabusLibrary.none => 'This paper will be marked without a syllabus.',
        _ => 'Syllabus chosen: ${syllabusInUse?.name ?? 'saved'}.',
      },
      if (marked) 'Re-mark to apply it.',
    ].join(' '));
  }
}
