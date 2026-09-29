import 'package:flutter/material.dart';

import 'dialogs.dart';
import 'theme.dart';

DateTime? _readDate(String text) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) return null;
  final date = DateTime.tryParse(text);
  if (date == null || date.year < 1900 || date.year > 2100) return null;
  if ('${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}' !=
      text) {
    return null;
  }
  return date;
}

String _dateText(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// A compact desktop range picker for the history search bar.
Future<DateTimeRange?> showCommitDateRangeDialog(
        BuildContext context, DateTimeRange? initial) =>
    showAppDialog<DateTimeRange>(
      context,
      title: '提交时间区间',
      minWidth: 360,
      maxWidth: 360,
      body: _DateRangeContent(initial: initial),
      actions: const [],
    );

class _DateRangeContent extends StatefulWidget {
  const _DateRangeContent({required this.initial});

  final DateTimeRange? initial;

  @override
  State<_DateRangeContent> createState() => _DateRangeContentState();
}

class _DateRangeContentState extends State<_DateRangeContent> {
  late DateTime? _start = widget.initial?.start;
  late DateTime? _end = widget.initial?.end;
  late DateTime _month;
  late final TextEditingController _startField;
  late final TextEditingController _endField;

  @override
  void initState() {
    super.initState();
    final initialMonth = widget.initial?.start ?? DateTime.now();
    _month = DateTime(initialMonth.year, initialMonth.month);
    _startField =
        TextEditingController(text: _start == null ? '' : _dateText(_start!));
    _endField =
        TextEditingController(text: _end == null ? '' : _dateText(_end!));
  }

  @override
  void dispose() {
    _startField.dispose();
    _endField.dispose();
    super.dispose();
  }

  bool get _ready => _start != null && _end != null && !_start!.isAfter(_end!);

  Widget _dateField(
      Palette p, String label, TextEditingController controller, bool isStart) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: color),
        );
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: ui.copyWith(color: p.textDim, fontSize: 11)),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            keyboardType: TextInputType.datetime,
            style: ui.copyWith(color: p.text, fontSize: 12.5),
            cursorColor: p.accent,
            decoration: InputDecoration(
              hintText: 'YYYY-MM-DD',
              hintStyle: ui.copyWith(color: p.textDim, fontSize: 12),
              isDense: true,
              filled: true,
              fillColor: p.bg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              enabledBorder: border(p.border),
              focusedBorder: border(p.accent),
            ),
            onChanged: (text) {
              final date = _readDate(text);
              setState(() {
                if (isStart) {
                  _start = date;
                } else {
                  _end = date;
                }
                if (date != null) _month = DateTime(date.year, date.month);
              });
            },
          ),
        ],
      ),
    );
  }

  void _selectDay(DateTime date) {
    setState(() {
      if (_start == null || _end != null || date.isBefore(_start!)) {
        _start = date;
        _end = null;
        _startField.text = _dateText(date);
        _endField.clear();
      } else {
        _end = date;
        _endField.text = _dateText(date);
      }
    });
  }

  Widget _dayCell(Palette p, int day, DateTime today) {
    final date = DateTime(_month.year, _month.month, day);
    final endpoint = date == _start || date == _end;
    final between = _start != null &&
        _end != null &&
        date.isAfter(_start!) &&
        date.isBefore(_end!);
    final isToday = date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Semantics(
        label: '${date.year}年${date.month}月$day日',
        button: true,
        selected: endpoint,
        excludeSemantics: true,
        onTap: () => _selectDay(date),
        child: Material(
          color: endpoint
              ? p.accent
              : between
                  ? p.bgSel
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            hoverColor: p.bgHover,
            onTap: () => _selectDay(date),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                border:
                    isToday && !endpoint ? Border.all(color: p.accent) : null,
              ),
              child: Text('$day',
                  style: ui.copyWith(
                      color: endpoint ? Colors.white : p.text, fontSize: 12)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _daySlot(Palette p, int day, int daysInMonth, DateTime today) {
    if (day < 1 || day > daysInMonth) {
      return const Expanded(child: SizedBox.shrink());
    }
    return Expanded(child: _dayCell(p, day, today));
  }

  Widget _monthButton(Palette p, int offset) {
    final disabled = offset < 0
        ? _month.year == 1900 && _month.month == 1
        : _month.year == 2100 && _month.month == 12;
    return IconButton(
      tooltip: offset < 0 ? '上个月' : '下个月',
      onPressed: disabled
          ? null
          : () => setState(
              () => _month = DateTime(_month.year, _month.month + offset)),
      icon: Icon(offset < 0 ? Icons.chevron_left : Icons.chevron_right),
      iconSize: 18,
      color: p.text,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final firstWeekday = _month.weekday - 1;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final weekCount = (firstWeekday + daysInMonth + 6) ~/ 7;
    final invalidInput = (_startField.text.isNotEmpty && _start == null) ||
        (_endField.text.isNotEmpty && _end == null);
    final reversed = _start != null && _end != null && _start!.isAfter(_end!);
    final message = invalidInput
        ? '请输入有效日期（1900—2100）'
        : reversed
            ? '结束日期不能早于开始日期'
            : _ready
                ? '已选择 ${_end!.difference(_start!).inDays + 1} 天'
                : '点击开始日期，再点击结束日期';
    final today = DateTime.now();

    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            _dateField(p, '开始日期', _startField, true),
            const SizedBox(width: 10),
            _dateField(p, '结束日期', _endField, false),
          ]),
          const SizedBox(height: 9),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(message,
                style: ui.copyWith(
                    color: invalidInput || reversed ? p.red : p.textDim,
                    fontSize: 11)),
          ),
          const SizedBox(height: 16),
          Row(children: [
            _monthButton(p, -1),
            Expanded(
              child: Text('${_month.year} 年 ${_month.month} 月',
                  textAlign: TextAlign.center,
                  style: ui.copyWith(
                      color: p.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
            _monthButton(p, 1),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            for (final label in ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: ui.copyWith(color: p.textDim, fontSize: 11)),
              ),
          ]),
          const SizedBox(height: 5),
          for (var week = 0; week < weekCount; week++)
            SizedBox(
              height: 38,
              child: Row(children: [
                for (var weekday = 0; weekday < 7; weekday++)
                  _daySlot(p, week * 7 + weekday - firstWeekday + 1,
                      daysInMonth, today),
              ]),
            ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              DialogButton('取消', onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 8),
              Opacity(
                opacity: _ready ? 1 : 0.45,
                child: DialogButton(
                  '确定',
                  kind: DialogButtonKind.primary,
                  onTap: () {
                    if (!_ready) return;
                    Navigator.of(context)
                        .pop(DateTimeRange(start: _start!, end: _end!));
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
