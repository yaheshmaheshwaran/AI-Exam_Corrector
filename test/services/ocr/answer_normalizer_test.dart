import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/services/ocr/answer_normalizer.dart';

const AnswerNormalizer normalizer = AnswerNormalizer();

String clean(String text) => normalizer.normalizeLine(text).text;

void main() {
  group('typographic characters', () {
    test('replaces smart quotes with plain ones', () {
      expect(clean('the cell’s membrane'), "the cell's membrane");
      expect(clean('“osmosis”'), '"osmosis"');
    });

    test('replaces dashes and the minus sign with a hyphen', () {
      expect(clean('50 – 20'), '50 - 20');
      expect(clean('x − y'), 'x - y');
    });

    test('expands ligatures', () {
      expect(clean('diﬀusion'), 'diffusion');
      expect(clean('ﬁbre'), 'fibre');
    });

    test('records what it replaced', () {
      final NormalizedLine result =
          normalizer.normalizeLine('the cell’s wall');

      expect(result.isChanged, isTrue);
      expect(result.changes.first.reason, contains('typographic'));
    });
  });

  group('letters misread as digits', () {
    test('corrects them inside a number', () {
      expect(clean('l2.5'), '12.5');
      expect(clean('O.05'), '0.05');
      expect(clean('l00'), '100');
    });

    test('will not rewrite a token that is mostly letters', () {
      // "2OO" is probably 200, and is deliberately left alone anyway: the same
      // rule that would fix it would turn the chemical formula SO2 into 502.
      // A missed correction costs a glance in review; a corrupted formula costs
      // the student marks.
      expect(clean('SO2'), 'SO2');
      expect(clean('2OO'), '2OO');
    });

    test('leaves real words alone', () {
      // The whole risk of this rule: "hello" must never become "he110".
      expect(clean('hello'), 'hello');
      expect(clean('solution'), 'solution');
      expect(clean('Osmosis'), 'Osmosis');
      expect(clean('cell'), 'cell');
    });

    test('leaves a unit attached to a number alone', () {
      expect(clean('50 mm'), '50 mm');
      expect(clean('0.05 mol'), '0.05 mol');
      expect(clean('pH7'), 'pH7');
    });

    test('leaves a token with no digits at all alone', () {
      // "SOIL" is all confusable characters but contains no digit, so there is
      // no evidence it was ever meant to be a number.
      expect(clean('SOIL'), 'SOIL');
      expect(clean('BOSS'), 'BOSS');
    });

    test('says why it changed a token', () {
      final NormalizedLine result = normalizer.normalizeLine('l00');

      expect(result.text, '100');
      expect(result.changes.first.before, 'l00');
      expect(result.changes.first.after, '100');
    });
  });

  group('spacing', () {
    test('collapses runs of spaces and trims', () {
      expect(clean('  glucose   +   oxygen  '), 'glucose + oxygen');
    });

    test('leaves already-clean text untouched', () {
      expect(normalizer.normalizeLine('glucose + oxygen').isChanged, isFalse);
    });
  });

  group('rejoining words split across a line break', () {
    test('joins a hyphenated word', () {
      // Only the broken word moves up. The remainder stays where it was, so
      // the text keeps the line structure the page actually had.
      expect(
        normalizer.joinHyphenatedLines('the mito-\nchondria makes ATP'),
        'the mitochondria\nmakes ATP',
      );
    });

    test('keeps the rest of the continuation line', () {
      expect(
        normalizer.joinHyphenatedLines('sur-\nface area increases'),
        'surface\narea increases',
      );
    });

    test('consumes the continuation line when it held only the word end', () {
      expect(
        normalizer.joinHyphenatedLines('the mito-\nchondria'),
        'the mitochondria',
      );
    });

    test('leaves a hyphen that is real punctuation alone', () {
      expect(
        normalizer.joinHyphenatedLines('a root - hair cell\nis adapted'),
        'a root - hair cell\nis adapted',
      );
    });

    test('never joins across a page boundary', () {
      const String block = 'the mito-\n\n--- Page 2 ---\nchondria';

      expect(normalizer.joinHyphenatedLines(block), block);
    });

    test('leaves text with no split words untouched', () {
      const String block = 'glucose + oxygen\ncarbon dioxide + water';

      expect(normalizer.joinHyphenatedLines(block), block);
    });
  });

  test('a student\'s spelling is never corrected', () {
    // The line this whole class walks: repairing the pipeline's damage is
    // legitimate, inventing an answer the student did not write is not.
    expect(clean('mitocondria'), 'mitocondria');
    expect(clean('The alveoli are surounded by muscle'),
        'The alveoli are surounded by muscle');
  });
}
