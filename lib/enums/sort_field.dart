import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/l10n/modu_strings.dart';
import 'package:flutter/material.dart';

enum SortFieldEnum {
  title,
  author,
  lastReadTime,
  progress,
  importTime,
  // Custom build: sort by the on-disk file name instead of the metadata title.
  fileName,
}

extension SortFieldExtension on SortFieldEnum {
  String getL10n(BuildContext context) {
    return switch (this) {
      SortFieldEnum.title => L10n.of(context).bookshelfTitle,
      SortFieldEnum.author => L10n.of(context).bookshelfAuthor,
      SortFieldEnum.lastReadTime => L10n.of(context).bookshelfLastReadTime,
      SortFieldEnum.progress => L10n.of(context).bookshelfProgress,
      SortFieldEnum.importTime => L10n.of(context).bookshelfImportTime,
      SortFieldEnum.fileName =>
        ModuStrings.text(context, '文件名', 'File name'),
    };
  }
}
