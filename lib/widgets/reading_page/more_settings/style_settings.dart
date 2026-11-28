import 'package:anx_reader/widgets/settings/setting_help_title.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import '../reader_menu_group.dart';
import 'package:anx_reader/enums/text_alignment.dart';
import 'package:anx_reader/enums/writing_mode.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/l10n/modu_strings.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/widgets/icon_and_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:anx_reader/service/ocr/document_text_style.dart';
import 'reader_setting_availability.dart';

// Reusable style slider widget that can be disabled
class StyleSlider extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) labelFormatter;
  final bool enabled;

  const StyleSlider({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    required this.min,
    required this.max,
    required this.divisions,
    required this.labelFormatter,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconAndText(
          icon: Icon(icon),
          text: label,
        ),
        Expanded(
          child: Slider(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            value: value,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
            min: min,
            max: max,
            divisions: divisions,
            label: labelFormatter(value),
          ),
        ),
      ],
    );
  }
}

class StyleSettings extends StatefulWidget {
  const StyleSettings(
      {super.key,
      this.documentStyle,
      this.saveDocumentStyle,
      this.readerMenu = false});
  final DocumentTextStyle? documentStyle;
  final Future<void> Function(DocumentTextStyle)? saveDocumentStyle;
  final bool readerMenu;

  @override
  State<StyleSettings> createState() => _StyleSettingsState();
}

class _StyleSettingsState extends State<StyleSettings> {
  bool get _document => widget.documentStyle != null;
  double get _readerWidth => MediaQuery.sizeOf(context).width;
  int _alignmentRevision = 0;

  Future<void> _saveBookStyle(BookStyle value, {String? field}) async {
    if (!_document) {
      epubPlayerKey.currentState?.changeStyle(value);
      Prefs().saveBookStyleToPrefs(value);
      return;
    }
    try {
      final values = {
        'margin': value.sideMargin * _readerWidth / 100,
        'topMargin': value.topMargin,
        'bottomMargin': value.bottomMargin,
        'spacing': value.letterSpacing,
      };
      await widget.saveDocumentStyle
          ?.call(widget.documentStyle!.withValue(field!, values[field]!));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(L10n.of(context).commonFailed)));
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget useBookStylesSwitch() {
      return SwitchListTile(
        title: SettingHelpTitle(
            title: L10n.of(context).useBookStyles,
            description: L10n.of(context).useBookStylesDescription),
        value: Prefs().useBookStyles,
        onChanged: (bool value) {
          setState(() {
            Prefs().useBookStyles = value;
            epubPlayerKey.currentState?.changeStyle(Prefs().bookStyle);
          });
        },
      );
    }

    // Reeden-style per-category publisher CSS control. The master switch above
    // wins; when it is off each flag decides whether one category of the
    // book's own CSS survives the reader typography overrides.
    Widget bookStyleDetails() {
      const modeKeys = ['reader', 'smart', 'book'];
      const modeZh = ['阅读设置', '智能适配', '保留书籍'];
      const modeEn = ['Reader', 'Smart', 'Book'];

      Widget flag(BuildContext ctx, String zh, String en, bool value,
          ValueChanged<bool> onChanged) {
        return SwitchListTile(
          title: Text(ModuStrings.text(ctx, zh, en)),
          value: value,
          onChanged: onChanged,
        );
      }

      Widget mode(BuildContext ctx, String zh, String en, int value,
          ValueChanged<int> onChanged) {
        return ListTile(
          title: Text(ModuStrings.text(ctx, zh, en)),
          trailing: DropdownMenu<int>(
            width: 132,
            initialSelection: value,
            dropdownMenuEntries: [
              for (var i = 0; i < modeKeys.length; i++)
                DropdownMenuEntry<int>(
                    value: i, label: ModuStrings.text(ctx, modeZh[i], modeEn[i])),
            ],
            onSelected: (v) {
              if (v != null) onChanged(v);
            },
          ),
        );
      }

      return ListTile(
        leading: const Icon(Icons.tune),
        title: Text(ModuStrings.text(context, '书籍样式细则', 'Book style details')),
        subtitle: Text(ModuStrings.text(
            context,
            '按类别保留 EPUB 自带样式，解决某一项调了不生效',
            'Keep publisher CSS per category when a layout setting has no effect')),
        onTap: () {
          final style = Prefs().bookStyle;
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (ctx) => SafeArea(
              child: SingleChildScrollView(
                child: StatefulBuilder(
                  builder: (ctx, sheetSetState) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          child: Text(
                            ModuStrings.text(
                                ctx,
                                '「使用书籍中的样式」打开时本页全部不生效；关闭后，下面每项决定该类书籍样式是否保留。智能适配只保护标题等特殊版式。',
                                'These apply only when "Use book styles" is off. Smart keeps special layouts such as headings.'),
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ),
                        flag(ctx, '保留书籍字体', 'Keep book font',
                            style.cssKeepFont, (v) {
                          sheetSetState(() => style.cssKeepFont = v);
                          _saveBookStyle(style);
                        }),
                        flag(ctx, '保留书籍字号', 'Keep book font size',
                            style.cssKeepFontSize, (v) {
                          sheetSetState(() => style.cssKeepFontSize = v);
                          _saveBookStyle(style);
                        }),
                        flag(ctx, '保留书籍字重', 'Keep book font weight',
                            style.cssKeepFontWeight, (v) {
                          sheetSetState(() => style.cssKeepFontWeight = v);
                          _saveBookStyle(style);
                        }),
                        flag(ctx, '保留文字颜色', 'Keep text color',
                            style.cssKeepColor, (v) {
                          sheetSetState(() => style.cssKeepColor = v);
                          _saveBookStyle(style);
                        }),
                        flag(ctx, '保留对齐与缩进', 'Keep alignment and indent',
                            style.cssKeepAlignIndent, (v) {
                          sheetSetState(() => style.cssKeepAlignIndent = v);
                          _saveBookStyle(style);
                        }),
                        mode(ctx, '行高模式', 'Line height mode',
                            style.cssLineHeightMode, (v) {
                          sheetSetState(() => style.cssLineHeightMode = v);
                          _saveBookStyle(style);
                        }),
                        mode(ctx, '段距模式', 'Paragraph spacing mode',
                            style.cssParagraphSpacingMode, (v) {
                          sheetSetState(() => style.cssParagraphSpacingMode = v);
                          _saveBookStyle(style);
                        }),
                        flag(ctx, '宽表格自动适配', 'Auto-fit wide tables',
                            style.cssAutoFitTables, (v) {
                          sheetSetState(() => style.cssAutoFitTables = v);
                          _saveBookStyle(style);
                        }),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    // Reeden has "copy layout / paste layout" at the bottom of its layout
    // panel. BookStyle.toJson already carries every field, including the new
    // CSS flags, so the clipboard payload stays portable across devices.
    Widget layoutClipboard() {
      Future<void> copy() async {
        await Clipboard.setData(ClipboardData(text: Prefs().bookStyle.toJson()));
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(ModuStrings.text(context, '排版已复制', 'Layout copied'))));
      }

      Future<void> paste() async {
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (text == null || text.isEmpty) return;
        try {
          final style = BookStyle.fromJson(text);
          Prefs().saveBookStyleToPrefs(style);
          epubPlayerKey.currentState?.changeStyle(style);
          if (!mounted) return;
          setState(() {});
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text(ModuStrings.text(context, '排版已粘贴', 'Layout pasted'))));
        } catch (_) {
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text(ModuStrings.text(context, '排版数据无效', 'Invalid layout data'))));
        }
      }

      return Row(children: [
        Expanded(
            child: OutlinedButton.icon(
                onPressed: copy,
                icon: const Icon(Icons.copy),
                label: Text(ModuStrings.text(context, '复制排版', 'Copy layout')))),
        const SizedBox(width: 8),
        Expanded(
            child: OutlinedButton.icon(
                onPressed: paste,
                icon: const Icon(Icons.checklist),
                label: Text(ModuStrings.text(context, '粘贴排版', 'Paste layout')))),
      ]);
    }

    Widget textIndent(BookStyle bookStyle, StateSetter setState) {
      bool enabled = !_document && !Prefs().useBookStyles;
      return StyleSlider(
        icon: Icons.format_indent_increase,
        label: L10n.of(context).readingPageIndent,
        value: bookStyle.indent,
        onChanged: (double value) {
          setState(() {
            bookStyle.indent = value;
            _saveBookStyle(bookStyle);
          });
        },
        min: -1,
        max: 8,
        divisions: 18,
        labelFormatter: (value) => value < 0
            ? L10n.of(context).readingPageIndentNoChange
            : value.toStringAsFixed(1),
        enabled: enabled,
      );
    }

    Widget indentPresets(BookStyle bookStyle, StateSetter setState) {
      const values = <double>[-1, 0, 1, 2, 3, 4];
      String label(double value) {
        if (value < 0) return ModuStrings.text(context, '默认', 'Default');
        if (value == 0) return ModuStrings.text(context, '无', 'None');
        return ModuStrings.format(context, '{n} 字', '{n} char',
            values: {'n': value.toStringAsFixed(0)});
      }

      final current = values.contains(bookStyle.indent) ? bookStyle.indent : 0.0;
      return Row(children: [
        const Icon(Icons.format_indent_increase),
        const SizedBox(width: 12),
        Text(L10n.of(context).readingPageIndent),
        const Spacer(),
        DropdownMenu<double>(
          width: 120,
          initialSelection: current,
          dropdownMenuEntries: [
            for (final value in values)
              DropdownMenuEntry<double>(value: value, label: label(value)),
          ],
          onSelected: (value) {
            if (value == null) return;
            setState(() {
              bookStyle.indent = value;
              _saveBookStyle(bookStyle);
            });
          },
        ),
      ]);
    }

    Widget sideMarginSlider(BookStyle bookStyle, StateSetter setState) {
      return StyleSlider(
        icon: !_document && Prefs().writingMode == WritingModeEnum.verticalRl
            ? Bootstrap.arrows_vertical
            : Bootstrap.arrows,
        label: !_document && Prefs().writingMode == WritingModeEnum.verticalRl
            ? L10n.of(context).readingPageVerticleMargin
            : L10n.of(context).readingPageSideMargin,
        value: bookStyle.sideMargin,
        onChanged: (double value) {
          setState(() {
            bookStyle.sideMargin = value;
            if (!_document) _saveBookStyle(bookStyle);
          });
        },
        onChangeEnd: _document
            ? (_) => _saveBookStyle(bookStyle, field: 'margin')
            : null,
        min: 0,
        max: 20,
        divisions: 20,
        labelFormatter: (value) => value.toStringAsFixed(1),
        enabled: true, // Side margin is always enabled
      );
    }

    Widget letterSpacingSlider(BookStyle bookStyle, StateSetter setState) {
      bool enabled = _document || !Prefs().useBookStyles;
      return StyleSlider(
        icon: Icons.compare_arrows,
        label: L10n.of(context).readingPageLetterSpacing,
        value: bookStyle.letterSpacing,
        onChanged: (double value) {
          setState(() {
            bookStyle.letterSpacing = value;
            if (!_document) _saveBookStyle(bookStyle);
          });
        },
        onChangeEnd: _document
            ? (_) => _saveBookStyle(bookStyle, field: 'spacing')
            : null,
        min: -3,
        max: 7,
        divisions: 10,
        labelFormatter: (value) => value.toString(),
        enabled: enabled,
      );
    }

    Widget wordSpacingSlider(BookStyle bookStyle, StateSetter setState) {
      bool enabled = !_document && !Prefs().useBookStyles;
      return StyleSlider(
        icon: Icons.compare_arrows,
        label: ModuStrings.text(context, '词间距', 'Word spacing'),
        value: bookStyle.wordSpacing,
        onChanged: (double value) {
          setState(() => bookStyle.wordSpacing = value);
          _saveBookStyle(bookStyle);
        },
        min: -2,
        max: 8,
        divisions: 20,
        labelFormatter: (value) => value.toStringAsFixed(1),
        enabled: enabled,
      );
    }

    Row topBottomMarginSlider(BookStyle bookStyle, StateSetter setState) {
      return Row(children: [
        !_document && Prefs().writingMode == WritingModeEnum.verticalRl
            ? IconAndText(
                icon: const Icon(Bootstrap.chevron_bar_right),
                text: L10n.of(context).readingPageRightMargin,
              )
            : IconAndText(
                icon: const Icon(Bootstrap.chevron_bar_up),
                text: L10n.of(context).readingPageTopMargin,
              ),
        Expanded(
          child: Slider(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            value: bookStyle.topMargin,
            onChanged: (double value) {
              setState(() {
                bookStyle.topMargin = value;
                if (!_document) _saveBookStyle(bookStyle);
              });
            },
            onChangeEnd: _document
                ? (_) => _saveBookStyle(bookStyle, field: 'topMargin')
                : null,
            min: 0,
            max: 200,
            divisions: 10,
            label: (bookStyle.topMargin / 20).toStringAsFixed(0),
          ),
        ),
        !_document && Prefs().writingMode == WritingModeEnum.verticalRl
            ? IconAndText(
                icon: const Icon(Bootstrap.chevron_bar_left),
                text: L10n.of(context).readingPageLeftMargin,
              )
            : IconAndText(
                icon: const Icon(Bootstrap.chevron_bar_down),
                text: L10n.of(context).readingPageBottomMargin,
              ),
        Expanded(
          child: Slider(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            value: bookStyle.bottomMargin,
            onChanged: (double value) {
              setState(() {
                bookStyle.bottomMargin = value;
                if (!_document) _saveBookStyle(bookStyle);
              });
            },
            onChangeEnd: _document
                ? (_) => _saveBookStyle(bookStyle, field: 'bottomMargin')
                : null,
            min: 0,
            max: 200,
            divisions: 10,
            label: (bookStyle.bottomMargin / 20).toStringAsFixed(0),
          ),
        ),
      ]);
    }

    Widget headingFontSizeSlider(BookStyle bookStyle, StateSetter setState) {
      bool enabled = !_document && !Prefs().useBookStyles;
      return StyleSlider(
        icon: Icons.title,
        label: L10n.of(context).headingFontSize,
        value: bookStyle.headingFontSize,
        onChanged: (double value) {
          setState(() {
            bookStyle.headingFontSize = value;
            _saveBookStyle(bookStyle);
          });
        },
        min: 0.5,
        max: 2.0,
        divisions: 15,
        labelFormatter: (value) => value.toStringAsFixed(1),
        enabled: enabled,
      );
    }

    Widget textAlignment() {
      final items = [
        {
          "icon": Icons.auto_awesome,
          "text": L10n.of(context).textAlignmentAuto,
          "value": TextAlignmentEnum.auto
        },
        {
          "icon": Icons.format_align_left,
          "text": L10n.of(context).textAlignmentLeft,
          "value": TextAlignmentEnum.left
        },
        {
          "icon": Icons.format_align_center,
          "text": L10n.of(context).textAlignmentCenter,
          "value": TextAlignmentEnum.center
        },
        {
          "icon": Icons.format_align_right,
          "text": L10n.of(context).textAlignmentRight,
          "value": TextAlignmentEnum.right
        },
        {
          "icon": Icons.format_align_justify,
          "text": L10n.of(context).textAlignmentJustify,
          "value": TextAlignmentEnum.justify
        },
      ];

      return StatefulBuilder(
        builder: (context, setState) => Row(
          children: [
            Icon(Icons.format_align_left,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Text(L10n.of(context).textAlignment),
            const Spacer(),
            DropdownMenu<TextAlignmentEnum>(
              width: 140,
              key: ValueKey(_document
                  ? (
                      widget.documentStyle!.textAlignment,
                      widget.documentStyle!.justify,
                      _alignmentRevision
                    )
                  : Prefs().textAlignment),
              initialSelection: _document
                  ? TextAlignmentEnum.fromCode(
                      widget.documentStyle!.textAlignment ??
                          (widget.documentStyle!.justify ? 'justify' : 'left'))
                  : Prefs().textAlignment,
              inputDecorationTheme: InputDecorationTheme(
                isDense: false,
                border: InputBorder.none,
              ),
              dropdownMenuEntries: items.map((item) {
                return DropdownMenuEntry<TextAlignmentEnum>(
                  value: item["value"] as TextAlignmentEnum,
                  label: item["text"] as String,
                  leadingIcon: Icon(item["icon"] as IconData),
                );
              }).toList(),
              onSelected: (value) {
                if (value != null) {
                  if (_document) {
                    final old = widget.documentStyle!;
                    widget.saveDocumentStyle
                        ?.call(old.withValue('textAlignment', value.code))
                        .catchError((Object error) {
                      if (context.mounted) {
                        this.setState(() => _alignmentRevision++);
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(
                                content: Text(L10n.of(context).commonFailed)));
                      }
                    });
                    return;
                  }
                  setState(() {
                    Prefs().textAlignment = value;
                    epubPlayerKey.currentState?.changeStyle(Prefs().bookStyle);
                  });
                }
              },
            ),
          ],
        ),
      );
    }

    Widget textSpacingTrimSwitch(BookStyle bookStyle, StateSetter setState) {
      return SwitchListTile(
        title: SettingHelpTitle(
          title: ModuStrings.text(context, '标点挤压', 'Punctuation trimming'),
          description: ModuStrings.text(
            context,
            '压缩行首行尾标点占用的空白，让中文排版更紧凑（对标 Reeden）。需较新系统 WebView 支持。',
            'Trim leading/trailing punctuation spacing for tighter Chinese layout. Requires a recent system WebView.',
          ),
        ),
        value: bookStyle.textSpacingTrim,
        onChanged: (bool value) {
          setState(() => bookStyle.textSpacingTrim = value);
          _saveBookStyle(bookStyle);
        },
      );
    }

    Widget sliders() {
      final document = widget.documentStyle;
      BookStyle bookStyle = document == null
          ? Prefs().bookStyle
          : BookStyle(
              sideMargin: (document.margin / _readerWidth * 100).clamp(0, 20),
              topMargin: document.padding.top,
              bottomMargin: document.padding.bottom,
              letterSpacing: document.spacing);
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => Column(
          children: [
            ReaderSettingAvailability(
                enabled: !_document,
                child: indentPresets(bookStyle, setState)),
            ReaderSettingAvailability(
                enabled: !_document, child: textIndent(bookStyle, setState)),
            ReaderSettingAvailability(
                enabled: !_document, child: bookStyleDetails()),
            sideMarginSlider(bookStyle, setState),
            topBottomMarginSlider(bookStyle, setState),
            letterSpacingSlider(bookStyle, setState),
            ReaderSettingAvailability(
                enabled: !_document && !Prefs().useBookStyles,
                child: wordSpacingSlider(bookStyle, setState)),
            ReaderSettingAvailability(
                enabled: !_document,
                child: headingFontSizeSlider(bookStyle, setState)),
            ReaderSettingAvailability(
                enabled: !_document && !Prefs().useBookStyles,
                child: textSpacingTrimSwitch(bookStyle, setState)),
            ReaderSettingAvailability(
                enabled: !_document, child: layoutClipboard()),
          ],
        ),
      );
    }

    if (!widget.readerMenu) {
      return Container(
        padding: const EdgeInsets.all(8),
        child: Column(children: [
          ReaderSettingAvailability(
              enabled: !_document, child: useBookStylesSwitch()),
          const Divider(),
          sliders(),
          const SizedBox(height: 16),
          const Divider(),
          textAlignment(),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReaderMenuGroup(
              padding: const EdgeInsets.all(12),
              child: ReaderSettingAvailability(
                  enabled: !_document, child: useBookStylesSwitch())),
          ReaderMenuGroup(padding: const EdgeInsets.all(12), child: sliders()),
          ReaderMenuGroup(
              padding: const EdgeInsets.all(12), child: textAlignment()),
        ],
      ),
    );
  }
}
