import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/l10n/modu_strings.dart';
import 'package:flutter/material.dart';

enum ReadingInfoEnum {
  none,
  chapterTitle,
  chapterProgress,
  chapterPageProgress,
  bookProgress,
  // Multi-dimensional progress. EPUB has real chapters; a PDF has one
  // section per physical page, so chapter-based values are meaningless
  // there and the book-wide dimensions are the useful ones.
  bookPageProgress,
  chapterPercentProgress,
  bookPageNumber,
  bookRemainingPages,
  battery,
  time,
  batteryAndTime,
}

/// Keep the newer, more explicit Chinese labels without dropping the
/// translations that already exist for the original three progress values.
String _localizedLabel(BuildContext context, String zh, String translated) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : translated;

extension ReadingInfoL10n on ReadingInfoEnum {
  String getL10n(BuildContext context) {
    switch (this) {
      case ReadingInfoEnum.none:
        return L10n.of(context).commonNone;
      case ReadingInfoEnum.chapterTitle:
        return L10n.of(context).readingPageReadingInfoChapterTitle;
      case ReadingInfoEnum.battery:
        return L10n.of(context).readingPageReadingInfoBattery;
      case ReadingInfoEnum.time:
        return L10n.of(context).readingPageReadingInfoTime;
      case ReadingInfoEnum.batteryAndTime:
        return L10n.of(context).readingPageReadingInfoBatteryAndTime;
      case ReadingInfoEnum.chapterProgress:
        return _localizedLabel(
            context,
            '章节序号进度',
            L10n.of(context).readingPageReadingInfoChapterProgress);
      case ReadingInfoEnum.chapterPageProgress:
        return _localizedLabel(
            context,
            '章节页码进度',
            L10n.of(context).readingPageReadingInfoChapterPageProgress);
      case ReadingInfoEnum.bookProgress:
        return _localizedLabel(
            context,
            '全书百分比进度',
            L10n.of(context).readingPageReadingInfoBookProgress);
      case ReadingInfoEnum.bookPageProgress:
        return ModuStrings.text(
            context, '全书页码进度', 'Book page progress');
      case ReadingInfoEnum.chapterPercentProgress:
        return ModuStrings.text(
            context, '章节百分比进度', 'Chapter percent');
      case ReadingInfoEnum.bookPageNumber:
        return ModuStrings.text(context, '当前页码', 'Current page');
      case ReadingInfoEnum.bookRemainingPages:
        return ModuStrings.text(context, '剩余页数', 'Pages left');
    }
  }
}

extension ReadingInfoEnumJson on ReadingInfoEnum {
  String toJson() {
    return name;
  }

  static ReadingInfoEnum fromJson(String json) {
    // A configuration exported by a newer build may contain a value this
    // build does not know yet; fall back instead of throwing on import.
    return ReadingInfoEnum.values.firstWhere(
      (e) => e.name == json,
      orElse: () => ReadingInfoEnum.none,
    );
  }
}
