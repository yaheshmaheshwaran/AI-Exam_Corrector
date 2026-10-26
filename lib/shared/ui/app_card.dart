import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_glass.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';

/// A glass card with an optional header: a title, a quieter subtitle, and
/// actions at the right. Cards never blur; they are a more opaque sheet of
/// glass over the backdrop, so what is on them stays crisp.
///
/// With [divided] the header sits above a hairline and the body is inset
/// below it — for large panels like the results. Without it the header and
/// body share one padded block — for the smaller panels beside a page.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.trailing,
    this.tone,
    this.divided = false,
    this.expandChild = false,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final Widget? trailing;

  /// A tinted card that carries a meaning — the syllabus bonus, for one.
  final ToneKind? tone;
  final bool divided;

  /// True when the card fills the height it is given and its body scrolls.
  final bool expandChild;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ToneKind? tone = this.tone;
    final Tone? t = tone == null ? null : c.tone(tone);
    final String? title = this.title;

    final Widget? header = title == null
        ? null
        : SectionHeader(
            title: title,
            subtitle: subtitle,
            trailing: trailing,
            colour: t?.foreground,
          );

    final Widget body;
    if (divided && header != null) {
      final Widget inset = Padding(padding: padding, child: child);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right - 4, 12),
            child: header,
          ),
          const Divider(height: 1),
          if (expandChild) Expanded(child: inset) else inset,
        ],
      );
    } else {
      body = Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
          children: <Widget>[
            if (header != null) ...<Widget>[header, const SizedBox(height: 10)],
            if (expandChild) Expanded(child: child) else child,
          ],
        ),
      );
    }

    return DecoratedBox(
      decoration: t == null
          ? AppGlass.card(radius: AppTheme.cardRadius)
          : BoxDecoration(
              color: t.fill,
              border: Border.all(color: t.border),
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
              boxShadow: AppGlass.cardLift,
            ),
      position: DecorationPosition.background,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: t == null ? AppGlass.rimOf(radius: AppTheme.cardRadius) : const BoxDecoration(),
        child: body,
      ),
    );
  }
}

/// A title with an optional subtitle and actions at the right.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.colour,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final String? subtitle = this.subtitle;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.title.copyWith(color: colour),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.caption),
                ),
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}
