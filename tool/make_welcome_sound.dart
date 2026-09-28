// Generates `assets/sounds/welcome.wav`: the chime the opening screen plays as
// its reading beam settles.
//
// Run from the project root with:  dart run tool/make_welcome_sound.dart
//
// One warm note (A5) with two quiet overtones and a faint bell partial that
// fades first. A rounded 12 ms start means no click; a smooth decay leaves
// silence by 1.1 s. It is normalised to the same peak as the app's other
// sounds (about -22 dBFS), so it is never louder than a button press.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int _rate = 44100;
const double _seconds = 1.1;
const double _note = 880; // A5
const double _peakDbfs = -22;

void main() {
  final int count = (_rate * _seconds).round();
  final Float64List samples = Float64List(count);

  double wave(double frequency, double t) => math.sin(2 * math.pi * frequency * t);

  for (int i = 0; i < count; i++) {
    final double t = i / _rate;
    const double attack = 0.012;
    const double release = 0.15;
    final double rise = t < attack ? 0.5 - 0.5 * math.cos(math.pi * t / attack) : 1;
    final double fall = t > _seconds - release
        ? 0.5 + 0.5 * math.cos(math.pi * (t - (_seconds - release)) / release)
        : 1;
    final double tone = wave(_note, t) +
        0.18 * wave(_note * 2, t) * math.exp(-t / 0.25) +
        0.05 * wave(_note * 3, t) * math.exp(-t / 0.18) +
        0.04 * wave(_note * 2.76, t) * math.exp(-t / 0.08);
    samples[i] = tone * rise * fall * math.exp(-t / 0.35);
  }

  double peak = 0;
  for (final double s in samples) {
    peak = math.max(peak, s.abs());
  }
  final double gain = math.pow(10, _peakDbfs / 20) / peak;

  final ByteData pcm = ByteData(count * 2);
  for (int i = 0; i < count; i++) {
    pcm.setInt16(i * 2, (samples[i] * gain * 32767).round(), Endian.little);
  }

  final ByteData header = ByteData(44);
  void ascii(int offset, String text) {
    for (int i = 0; i < text.length; i++) {
      header.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + count * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // PCM chunk size
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, _rate, Endian.little);
  header.setUint32(28, _rate * 2, Endian.little); // bytes per second
  header.setUint16(32, 2, Endian.little); // bytes per frame
  header.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  header.setUint32(40, count * 2, Endian.little);

  final File file = File('assets/sounds/welcome.wav');
  file.writeAsBytesSync(<int>[...header.buffer.asUint8List(), ...pcm.buffer.asUint8List()]);
  stdout.writeln('Wrote ${file.path} (${_seconds}s, peak $_peakDbfs dBFS)');
}
