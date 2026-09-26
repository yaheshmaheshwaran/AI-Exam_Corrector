import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/json_read.dart';

/// Where one request to the model has got to.
enum ModelCallStatus { running, waiting, succeeded, failed }

/// One request the application made to the model, for the teacher to see.
class ModelCall {
  ModelCall({
    required this.id,
    required this.purpose,
    required this.model,
    required this.startedAt,
  });

  final int id;

  /// What it was for: "marking", "syllabus reading".
  final String purpose;
  String model;
  final DateTime startedAt;
  DateTime? finishedAt;
  ModelCallStatus status = ModelCallStatus.running;

  /// HTTP requests sent for it, retries included — each counts against the
  /// provider's limits.
  int attempts = 0;

  /// While waiting out a rate limit: when the next attempt goes.
  DateTime? retryAt;

  /// Why it waited or failed.
  String message = '';

  Duration elapsed(DateTime now) => (finishedAt ?? now).difference(startedAt);
}

/// A model's use today.
class ModelDayUsage {
  ModelDayUsage({this.requests = 0, this.failures = 0, this.rateLimited = 0});

  int requests;
  int failures;
  int rateLimited;

  JsonMap toJson() => <String, Object?>{
        'requests': requests,
        'failures': failures,
        'rateLimited': rateLimited,
      };

  static ModelDayUsage fromJson(JsonMap json) => ModelDayUsage(
        requests: readInt(json['requests']) ?? 0,
        failures: readInt(json['failures']) ?? 0,
        rateLimited: readInt(json['rateLimited']) ?? 0,
      );
}

/// Keeps count of the model's use and remembers its limits, so the teacher
/// can see at a glance whether the AI is working, waiting out a rate limit,
/// or out of quota for the day — and so a model known to be out of quota is
/// not asked again until its allowance comes back.
///
/// Counts are kept per provider day (the free tier resets at midnight
/// Pacific time) and saved, so they survive a restart.
class ModelUsageMonitor extends ChangeNotifier {
  ModelUsageMonitor({this.file, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// Where counts are saved; none in tests.
  final File? file;
  final DateTime Function() _clock;

  DateTime get now => _clock();

  final List<ModelCall> _recent = <ModelCall>[];
  final Map<String, ModelDayUsage> _today = <String, ModelDayUsage>{};
  final Map<String, DateTime> _exhaustedUntil = <String, DateTime>{};
  String _day = '';
  int _nextId = 0;

  static const int keepRecent = 40;

  /// Newest first.
  List<ModelCall> get recent => List<ModelCall>.unmodifiable(_recent.reversed);

  /// The request in progress, if any — the newest still running or waiting.
  ModelCall? get active {
    for (final ModelCall call in _recent.reversed) {
      if (call.status == ModelCallStatus.running || call.status == ModelCallStatus.waiting) {
        return call;
      }
    }
    return null;
  }

  Map<String, ModelDayUsage> get today {
    _rollOver();
    return Map<String, ModelDayUsage>.unmodifiable(_today);
  }

  int get requestsToday => today.values.fold<int>(0, (int sum, ModelDayUsage u) => sum + u.requests);

  /// When [model]'s daily allowance comes back, if it has run out.
  DateTime? exhaustedUntil(String model) {
    final DateTime? until = _exhaustedUntil[model];
    if (until == null) return null;
    if (!now.isBefore(until)) {
      _exhaustedUntil.remove(model);
      return null;
    }
    return until;
  }

  bool isExhausted(String model) => exhaustedUntil(model) != null;

  // --------------------------------------------------------------------------
  // Events, from the model client
  // --------------------------------------------------------------------------

  ModelCall started(String model, String purpose) {
    _rollOver();
    final ModelCall call = ModelCall(id: _nextId++, purpose: purpose, model: model, startedAt: now);
    _recent.add(call);
    if (_recent.length > keepRecent) _recent.removeAt(0);
    notifyListeners();
    return call;
  }

  /// Another HTTP request went out for [call].
  void attempted(ModelCall call) {
    _rollOver();
    _usage(call.model).requests++;
    call.attempts++;
    call
      ..status = ModelCallStatus.running
      ..retryAt = null;
    _save();
    notifyListeners();
  }

  /// [call] is waiting [wait] before trying again.
  void waiting(ModelCall call, Duration wait, CorrectionException reason) {
    if (reason.retryAfter != null || reason.quotaExhausted) _usage(call.model).rateLimited++;
    call
      ..status = ModelCallStatus.waiting
      ..retryAt = now.add(wait)
      ..message = reason.message;
    _save();
    notifyListeners();
  }

  /// [call] moved on to another model.
  void switchedModel(ModelCall call, String model) {
    call
      ..model = model
      ..status = ModelCallStatus.running
      ..retryAt = null;
    notifyListeners();
  }

  void succeeded(ModelCall call) {
    call
      ..status = ModelCallStatus.succeeded
      ..finishedAt = now
      ..retryAt = null
      ..message = '';
    notifyListeners();
  }

  /// [call] failed on [model]. A used-up daily allowance is remembered until
  /// it resets; one whose window was not stated, for a few minutes.
  void failed(ModelCall call, AppException error, {String? model}) {
    final String on = model ?? call.model;
    _usage(on).failures++;
    if (error is CorrectionException && error.quotaExhausted) {
      _exhaustedUntil[on] = error.dailyQuota
          ? nextQuotaReset(now)
          : now.add(const Duration(minutes: 5));
    }
    call
      ..status = ModelCallStatus.failed
      ..finishedAt = now
      ..retryAt = null
      ..message = error.message;
    _save();
    notifyListeners();
  }

  /// A failure on one model that the request survived by moving on.
  void modelFailed(ModelCall call, String model, CorrectionException error) {
    _usage(model).failures++;
    if (error.quotaExhausted) {
      _exhaustedUntil[model] = error.dailyQuota
          ? nextQuotaReset(now)
          : now.add(const Duration(minutes: 5));
    }
    _save();
    notifyListeners();
  }

  // --------------------------------------------------------------------------

  ModelDayUsage _usage(String model) => _today.putIfAbsent(model, ModelDayUsage.new);

  /// The provider's day: its daily allowances reset at midnight Pacific time.
  static String quotaDay(DateTime now) {
    final DateTime pacific = now.toUtc().subtract(Duration(hours: _pacificOffset(now.toUtc())));
    return '${pacific.year}-${pacific.month.toString().padLeft(2, '0')}-${pacific.day.toString().padLeft(2, '0')}';
  }

  /// When the next daily allowance begins: the coming midnight Pacific time,
  /// in local time.
  static DateTime nextQuotaReset(DateTime now) {
    final DateTime utc = now.toUtc();
    final int offset = _pacificOffset(utc);
    final DateTime pacific = utc.subtract(Duration(hours: offset));
    final DateTime midnight = DateTime.utc(pacific.year, pacific.month, pacific.day + 1);
    return midnight.add(Duration(hours: _pacificOffset(midnight.add(Duration(hours: offset))))).toLocal();
  }

  /// Hours Pacific time is behind UTC: 7 in daylight saving (second Sunday of
  /// March to the first Sunday of November), 8 otherwise.
  static int _pacificOffset(DateTime utc) {
    DateTime nthSunday(int year, int month, int n) {
      DateTime day = DateTime.utc(year, month, 1);
      while (day.weekday != DateTime.sunday) {
        day = day.add(const Duration(days: 1));
      }
      return day.add(Duration(days: 7 * (n - 1)));
    }

    final DateTime start = nthSunday(utc.year, 3, 2).add(const Duration(hours: 10)); // 2am PST
    final DateTime end = nthSunday(utc.year, 11, 1).add(const Duration(hours: 9)); // 2am PDT
    return !utc.isBefore(start) && utc.isBefore(end) ? 7 : 8;
  }

  /// A new provider day starts every count afresh.
  void _rollOver() {
    final String day = quotaDay(now);
    if (day == _day) return;
    _day = day;
    _today.clear();
  }

  /// Reads the saved counts, when there are any for today.
  Future<void> load() async {
    final File? target = file;
    if (target == null || !await target.exists()) return;
    try {
      final JsonMap? json = readMap(jsonDecode(await target.readAsString()));
      if (json == null) return;
      _rollOver();
      if (readString(json['day']) == _day) {
        for (final MapEntry<String, Object?> entry
            in (readMap(json['models']) ?? const <String, Object?>{}).entries) {
          if (readMap(entry.value) case final JsonMap usage) {
            _today[entry.key] = ModelDayUsage.fromJson(usage);
          }
        }
      }
      for (final MapEntry<String, Object?> entry
          in (readMap(json['exhaustedUntil']) ?? const <String, Object?>{}).entries) {
        final DateTime? until = DateTime.tryParse(readString(entry.value) ?? '')?.toLocal();
        if (until != null && until.isAfter(now)) _exhaustedUntil[entry.key] = until;
      }
      notifyListeners();
    } on FormatException {
      // A damaged file only loses today's counts.
    } on FileSystemException {
      // As above.
    }
  }

  Future<void> _saving = Future<void>.value();

  /// Resolves once every change so far is on disk.
  Future<void> get saved => _saving;

  /// Writes queue behind one another, and each writes the state as it is
  /// when its turn comes — so an older write never lands after a newer one.
  void _save() {
    final File? target = file;
    if (target == null) return;
    _saving = _saving.then((_) async {
      final String json = jsonEncode(<String, Object?>{
        'day': _day,
        'models': <String, Object?>{
          for (final MapEntry<String, ModelDayUsage> e in _today.entries) e.key: e.value.toJson(),
        },
        'exhaustedUntil': <String, Object?>{
          for (final MapEntry<String, DateTime> e in _exhaustedUntil.entries)
            e.key: e.value.toUtc().toIso8601String(),
        },
      });
      try {
        await target.parent.create(recursive: true);
        await target.writeAsString(json);
      } on FileSystemException {
        // Counting is a convenience: a failed save must never fail a request.
      }
    });
  }
}
