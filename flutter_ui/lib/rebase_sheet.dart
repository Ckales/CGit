import 'package:flutter/material.dart';

import 'context_menu.dart';
import 'rebase_plan.dart';
import 'theme.dart';

/// The interactive-rebase dialog: reorder, pick an action per commit, reword.
///
/// Rows are listed in the order git applies them, oldest at the top. The Tauri
/// version does the same and says so in the title — showing newest-first the
/// way the history list does would invert the meaning of "move up".
class RebaseSheet extends StatefulWidget {
  const RebaseSheet({
    super.key,
    required this.plan,
    required this.dirtyWorktree,
    required this.onClose,
    required this.onStart,
  });

  final RebasePlan plan;

  /// Whether there are uncommitted changes. git refuses to rebase a dirty
  /// worktree, so this decides whether autostash starts checked.
  final bool dirtyWorktree;

  final VoidCallback onClose;

  /// Called with the assembled todo, the reword queue in the same order, and
  /// whether to autostash.
  final Future<void> Function({
    required String todo,
    required List<String> messages,
    required bool autostash,
  }) onStart;

  @override
  State<RebaseSheet> createState() => _RebaseSheetState();
}

class _RebaseSheetState extends State<RebaseSheet> {
  late bool _autostash = widget.dirtyWorktree;
  final _rewordControllers = <RebaseStep, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _rewordControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  RebasePlan get _plan => widget.plan;

  void _move(int index, int by) {
    setState(() {
      _plan.move(index, by);
      _plan.markReordered();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final problem = _plan.problem;
    final canStart = problem == null && !_plan.isNoop;

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Container(
            width: 720,
            height: 560,
            decoration: BoxDecoration(
              color: p.bg,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: p.bgAlt,
                    border: Border(bottom: BorderSide(color: p.border)),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '交互式变基（${_plan.steps.length} 个提交，从上到下依次应用）',
                        style: ui.copyWith(color: p.text),
                      ),
                      const Spacer(),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: widget.onClose,
                          child:
                              Text('✕', style: ui.copyWith(color: p.textDim)),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _plan.steps.length,
                    itemBuilder: (context, i) => _row(p, i),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p.border)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Offered as a visible choice, pre-checked only when it is
                      // actually needed: silently stashing someone's work is not
                      // ours to decide.
                      _autostashRow(p),
                      if (problem != null) ...[
                        const SizedBox(height: 6),
                        Text(problem,
                            style: ui.copyWith(color: p.red, fontSize: 11)),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (problem == null && _plan.isNoop)
                            Text('还没有任何改动——变基会重写所有哈希却什么也不改变',
                                style: ui.copyWith(
                                    color: p.textDim, fontSize: 11)),
                          const Spacer(),
                          _button(p, '取消', widget.onClose),
                          const SizedBox(width: 6),
                          _button(
                            p,
                            '开始变基',
                            canStart
                                ? () => widget.onStart(
                                      todo: _plan.todoText,
                                      messages: _plan.rewordMessages,
                                      autostash: _autostash,
                                    )
                                : null,
                            primary: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(Palette p, int i) {
    final step = _plan.steps[i];
    final invalid = !_plan.stepIsValid(i);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: invalid ? p.red.withValues(alpha: 0.10) : null,
        border:
            Border(bottom: BorderSide(color: p.border.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          _arrow(p, '↑', i > 0, () => _move(i, -1)),
          _arrow(p, '↓', i < _plan.steps.length - 1, () => _move(i, 1)),
          const SizedBox(width: 8),
          // The app's own menu rather than DropdownButton: its Material popup
          // brings 48px rows and its own surface colour into a 24px-row list.
          _ActionPicker(
            action: step.action,
            palette: p,
            onPick: (a) => setState(() => step.action = a),
          ),
          const SizedBox(width: 8),
          Text(step.oid.substring(0, 7),
              style: mono.copyWith(color: p.textDim, fontSize: 11)),
          const SizedBox(width: 8),
          Expanded(
            child: step.action == RebaseAction.reword
                ? SizedBox(
                    height: 24,
                    child: TextField(
                      controller: _rewordControllers.putIfAbsent(
                        step,
                        () => TextEditingController(
                            text: step.message ?? step.summary),
                      ),
                      style: ui.copyWith(color: p.text, fontSize: 12),
                      cursorColor: p.accent,
                      onChanged: (v) => step.message = v,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 6),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(3),
                          borderSide: BorderSide(color: p.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(3),
                          borderSide: BorderSide(color: p.border),
                        ),
                      ),
                    ),
                  )
                : Text(
                    step.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui.copyWith(
                      color:
                          step.action == RebaseAction.drop ? p.textDim : p.text,
                      decoration: step.action == RebaseAction.drop
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _arrow(Palette p, String glyph, bool enabled, VoidCallback onTap) =>
      MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            child: Text(glyph,
                style: ui.copyWith(color: enabled ? p.text : p.textDim)),
          ),
        ),
      );

  Widget _autostashRow(Palette p) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() => _autostash = !_autostash),
          child: Row(
            children: [
              Container(
                width: 13,
                height: 13,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _autostash ? p.accent : p.bg,
                  border: Border.all(color: _autostash ? p.accent : p.border),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: _autostash
                    ? const Text('✓',
                        style: TextStyle(
                            fontSize: 9, color: Color(0xFFFFFFFF), height: 1))
                    : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.dirtyWorktree
                      ? '工作区有未提交改动 — 变基前自动储藏并在结束后恢复 (--autostash)'
                      : '变基前自动储藏工作区改动 (--autostash)',
                  style: ui.copyWith(color: p.textDim, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _button(Palette p, String label, VoidCallback? onTap,
          {bool primary = false}) =>
      MouseRegion(
        cursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: primary && onTap != null ? p.accent : p.bgElev,
              border: Border.all(
                  color: primary && onTap != null ? p.accent : p.border),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              label,
              style: ui.copyWith(
                color: onTap == null
                    ? p.textDim
                    : (primary ? const Color(0xFFFFFFFF) : p.text),
              ),
            ),
          ),
        ),
      );
}

/// The per-commit action picker: field-shaped, opening the app's flat menu.
class _ActionPicker extends StatefulWidget {
  const _ActionPicker({
    required this.action,
    required this.palette,
    required this.onPick,
  });

  final RebaseAction action;
  final Palette palette;
  final void Function(RebaseAction) onPick;

  @override
  State<_ActionPicker> createState() => _ActionPickerState();
}

class _ActionPickerState extends State<_ActionPicker> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final drop = widget.action == RebaseAction.drop;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapUp: (_) => showRepoMenu(
          context: context,
          position: menuAnchorBelow(context),
          items: [
            for (final a in RebaseAction.values)
              MenuAction(
                rebaseActionLabels[a]!,
                () => widget.onPick(a),
                danger: a == RebaseAction.drop,
                checked: a == widget.action,
              ),
          ],
        ),
        child: Container(
          width: 104,
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _hover ? p.bgHover : p.bgElev,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  rebaseActionLabels[widget.action]!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      ui.copyWith(color: drop ? p.red : p.text, fontSize: 12),
                ),
              ),
              Chevron(color: p.textDim),
            ],
          ),
        ),
      ),
    );
  }
}
