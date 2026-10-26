import 'package:flutter/material.dart';

/// Liquid glass: the values every glass surface shares.
///
/// Two kinds of glass sit over the Warm mist backdrop. The floating bars —
/// the rail, toolbars and the command footer — blur what passes beneath
/// them (see `Frosted`). Content cards never blur: they are a more opaque
/// sheet, so marks and text stay crisp, and cost nothing to draw.
abstract final class AppGlass {
  /// The floating bars with blur on: half white over the blurred content.
  static const Color barFill = Color(0x80FFFFFF);

  /// The same bars with blur off: nearly solid, so text never sits over a
  /// sharp picture of the content beneath.
  static const Color solidFill = Color(0xF0FFFFFF);

  /// Content cards: sections, tables, question panels.
  static const Color cardFill = Color(0xADFFFFFF);

  /// The bright inner edge that catches the light.
  static const Color rim = Color(0xE6FFFFFF);

  /// The faint outer line that separates glass from what is behind it.
  static const Color hairline = Color(0x12171717);

  /// The command pane's espresso glass: a latte tone, a shade deeper at its
  /// foot, that sets the place where marking starts apart from the white
  /// cards above it.
  static const List<Color> espressoFill = <Color>[Color(0xF5F0E7DE), Color(0xF0E4D7CA)];

  /// Its outer line, a shade of the accent rather than the neutral hairline.
  static const Color espressoEdge = Color(0x2E3E2F23);

  /// How strongly the bars blur, and how much colour they keep through it.
  static const double blurSigma = 12;
  static const double saturation = 1.6;

  /// The top of a bar catches the light: this much white over its fill at
  /// the top, less by the middle, a little again at the foot.
  static const double sheenTop = 0.72;
  static const double sheenMiddle = 0.2;
  static const double sheenFoot = 0.3;

  /// A soft, warm lift under floating glass.
  static const List<BoxShadow> lift = <BoxShadow>[
    BoxShadow(color: Color(0x0A171717), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x123E2F23), blurRadius: 28, offset: Offset(0, 10)),
  ];

  /// A gentler lift under content cards.
  static const List<BoxShadow> cardLift = <BoxShadow>[
    BoxShadow(color: Color(0x08171717), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F3E2F23), blurRadius: 22, offset: Offset(0, 8)),
  ];

  /// The outer hairline, drawn just outside the shape.
  static const BorderSide edge = BorderSide(
    color: hairline,
    width: 0.5,
    strokeAlign: BorderSide.strokeAlignOutside,
  );

  /// A content card's surface.
  static BoxDecoration card({double radius = 16, Color fill = cardFill}) => BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: const Border.fromBorderSide(edge),
        boxShadow: cardLift,
      );

  /// The bright inner rim, laid over a surface as its foreground.
  static BoxDecoration rimOf({double radius = 16}) => BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: rim),
      );
}

/// How long things move, and how. Everything is instant when the system
/// asks for reduced motion.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 180);
  static const Duration slow = Duration(milliseconds: 240);
  static const Curve curve = Curves.easeOutCubic;

  /// Whether the system asks for reduced motion.
  static bool still(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration], or none under reduced motion.
  static Duration of(BuildContext context, Duration duration) => still(context) ? Duration.zero : duration;
}
