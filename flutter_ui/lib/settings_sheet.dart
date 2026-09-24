import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_settings.dart';
import 'context_menu.dart';
import 'git.dart';
import 'git_text.dart';
import 'op_log.dart';
import 'prefs.dart';
import 'theme.dart';

/// 设置：通用 / 外观 / 编辑器 / Git 信息 / AI。
///
/// Two rules here are easy to lose and are kept deliberately:
///
///  * 主题 and 字号 preview live and 取消 puts them back. Picking a font size you
///    cannot see until you commit to it is not a choice, it is a guess.
///  * The credential button saves and tests on its own, outside 保存. It talks to
///    git's helper and to the network, so it cannot be part of a dialog-wide
///    commit that the user might still cancel.
///
/// The token fields stay write-only: core never hands a stored credential back,
/// so there is nothing to prefill, and empty means "keep what is saved".
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.git,
    required this.prefs,
    required this.ai,
    required this.onClose,
    required this.onPreview,
    required this.onSaved,
  });

  /// Null when no repository is open — 通用 / 外观 / 编辑器 / AI still apply, and
  /// the Git 信息 pane says why it is empty instead of hiding itself.
  final Git? git;
  final Prefs prefs;
  final AiSettings? ai;
  final VoidCallback onClose;

  /// Applies 主题 / 字号 without persisting, for the live preview.
  final void Function(bool dark, int fontSize) onPreview;

  /// Everything saved and persisted; the caller re-reads prefs and refreshes.
  final VoidCallback onSaved;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

const _panes = ['通用', '外观', '编辑器', 'Git 信息', 'AI'];

class _SettingsSheetState extends State<SettingsSheet> {
  int _pane = 0;

  /* ---------- 通用 ---------- */
  late String _pullStrategy = widget.prefs.pullStrategy;
  late int _pageSize = widget.prefs.historyPageSize;
  late bool _opLog = widget.prefs.opLog;

  /* ---------- 外观 ---------- */
  late bool _dark = widget.prefs.isDark;
  late int _fontSize = widget.prefs.fontSize;
  late bool _split = widget.prefs.isSplitDiff;

  /* ---------- 编辑器 ---------- */
  late String _editor = widget.prefs.editor;
  late final Set<String> _chosen = {...widget.prefs.editors};
  List<String> _installed = const [];
  Map<String, Uint8List?> _icons = const {};
  String? _editorScanError;

  /* ---------- Git 信息 ---------- */
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _token = TextEditingController();
  GitCredentialInfo? _credential;
  bool _globalIdentity = false;
  String _credentialResult = '';
  bool _credentialFailed = false;
  bool _credentialBusy = false;

  /* ---------- AI ---------- */
  final _aiUrl = TextEditingController();
  final _aiModel = TextEditingController();
  final _aiToken = TextEditingController();
  final _aiPrompt = TextEditingController();
  bool _aiTokenStored = false;
  String _aiResult = '';
  bool _aiFailed = false;
  bool _aiBusy = false;

  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _email,
      _username,
      _token,
      _aiUrl,
      _aiModel,
      _aiToken,
      _aiPrompt,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAll() async {
    final git = widget.git;
    if (git != null) {
      try {
        final identity = await git.identity();
        final credential = await git.credential();
        if (!mounted) return;
        setState(() {
          _name.text = identity.name;
          _email.text = identity.email;
          _credential = credential;
          _username.text = credential.username;
        });
      } on GitError catch (e) {
        if (mounted) _report(e.message, isError: true);
      }
    }

    // Scanned in parallel with the icons below it: opening the dialog used to
    // wait on one `sips` per editor, which is visible for a dozen of them.
    try {
      final installed = await Git.editors();
      final rows = {...installed, ..._chosen}.toList()..sort();
      final icons = await Future.wait(rows.map(Git.editorIcon));
      if (mounted) {
        setState(() {
          _installed = installed;
          _icons = {for (final (i, name) in rows.indexed) name: icons[i]};
        });
      }
    } catch (e) {
      // Everything, not just GitError: the scan shells out to the system and
      // the pane's job is to say why it is empty — an unreported empty list
      // looks like "no editors installed".
      if (mounted) setState(() => _editorScanError = '$e');
    }

    final ai = widget.ai;
    if (ai != null && mounted) {
      setState(() {
        _aiUrl.text = ai.baseUrl;
        _aiModel.text = ai.model;
        _aiPrompt.text = ai.prompt;
      });
      final has = await ai.readToken() != null;
      if (mounted) setState(() => _aiTokenStored = has);
    }
  }

  /// Every editor to list: the ones on this machine plus any still ticked from
  /// a machine that had them. Without the second half a stale tick could not be
  /// removed, because its row would not be drawn.
  List<String> get _editorRows =>
      ({..._installed, ..._chosen}.toList()..sort());

  List<String> get _editorOptions => ['', ...(_chosen.toList()..sort())];

  void _report(String text, {bool isError = false}) => setState(() {
        _message = text;
        _messageIsError = isError;
      });

  void _preview() => widget.onPreview(_dark, _fontSize);

  void _cancel() {
    // Put the live preview back before leaving, or cancelling would keep the
    // very thing it was supposed to discard.
    widget.onPreview(widget.prefs.isDark, widget.prefs.fontSize);
    widget.onClose();
  }

  Future<void> _save() async {
    final prefs = widget.prefs;
    await prefs.setPullStrategy(_pullStrategy);
    await prefs.setHistoryPageSize(_pageSize);
    await prefs.setOpLog(_opLog);
    await prefs.setDark(_dark);
    await prefs.setFontSize(_fontSize);
    await prefs.setSplitDiff(_split);
    await prefs.setEditors(_chosen.toList()..sort());
    await prefs.setEditor(_chosen.contains(_editor) ? _editor : '');

    // An editor that is no longer ticked cannot be chosen anywhere, so a
    // project still pointing at it would open nothing with no way to fix it.
    final projects = {...prefs.projectEditors}
      ..removeWhere((_, name) => name.isNotEmpty && !_chosen.contains(name));
    await prefs.setProjectEditors(projects);

    final ai = widget.ai;
    if (ai != null) {
      await ai.setBaseUrl(_aiUrl.text);
      await ai.setModel(_aiModel.text);
      await ai.setPrompt(_aiPrompt.text);
      if (_aiToken.text.trim().isNotEmpty) {
        await ai.writeToken(_aiToken.text);
      }
    }

    final git = widget.git;
    if (git != null &&
        (_name.text.trim().isNotEmpty || _email.text.trim().isNotEmpty)) {
      try {
        await git.setIdentity(
          _name.text.trim(),
          _email.text.trim(),
          global: _globalIdentity,
        );
      } on GitError catch (e) {
        if (mounted) _report(e.message, isError: true);
        return;
      }
    }

    widget.onSaved();
  }

  /// One button for the whole credential flow, because the useful action
  /// depends on what is already stored.
  Future<void> _credentialAction() async {
    final git = widget.git;
    if (git == null) return;

    final action = credentialAction(
      hasCredential: _credential?.hasCredential ?? false,
      infoUsername: _credential?.username,
      username: _username.text,
      token: _token.text,
    );
    if (action == 'missing-username' || action == 'missing-token') {
      setState(() {
        _credentialFailed = true;
        _credentialResult =
            action == 'missing-username' ? '请填写远端用户名' : '切换账号时请填写访问令牌';
      });
      return;
    }

    setState(() {
      _credentialBusy = true;
      _credentialFailed = false;
      _credentialResult = action == 'save-and-test' ? '正在保存凭据…' : '正在验证…';
    });
    try {
      if (action == 'save-and-test') {
        final info =
            await git.saveCredential(_username.text.trim(), _token.text);
        // Cleared the moment it reaches git's helper: this app has no reason
        // to go on holding it.
        _token.clear();
        if (mounted) setState(() => _credential = info);
      }
      final ok = await git.testCredential();
      if (mounted) {
        setState(() {
          _credentialFailed = false;
          _credentialResult = ok;
        });
      }
    } on GitError catch (e) {
      if (mounted) {
        setState(() {
          _credentialFailed = true;
          _credentialResult = e.message;
        });
      }
    } finally {
      _token.clear();
      if (mounted) setState(() => _credentialBusy = false);
    }
  }

  /// A round trip against a fixed sample diff.
  Future<void> _testAi() async {
    if (_aiUrl.text.trim().isEmpty || _aiModel.text.trim().isEmpty) {
      setState(() {
        _aiFailed = true;
        _aiResult = '请先填写请求地址和模型';
      });
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiFailed = false;
      _aiResult = '请求中…';
    });
    try {
      // The field wins when it has something typed; otherwise the stored token
      // is used, so testing without retyping it works.
      final typed = _aiToken.text.trim();
      final token =
          typed.isNotEmpty ? typed : (await widget.ai?.readToken() ?? '');
      final reply = await Git.aiChat(
        url: aiEndpoint(_aiUrl.text.trim()),
        token: token,
        model: _aiModel.text.trim(),
        system: _aiPrompt.text,
        user: '以下是已暂存的 git diff：\n\ndiff --git a/README.md b/README.md\n'
            '--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n # cgit\n+一个 Git 客户端\n',
      );
      if (mounted) {
        setState(() {
          _aiFailed = false;
          _aiResult = '连接正常，返回：${reply.split('\n').first}';
        });
      }
    } on GitError catch (e) {
      if (mounted) {
        setState(() {
          _aiFailed = true;
          _aiResult = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Container(
            width: 660,
            height: 540,
            decoration: BoxDecoration(
              color: p.bg,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _titleBar(p),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _nav(p),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          children: switch (_pane) {
                            0 => _generalPane(p),
                            1 => _lookPane(p),
                            2 => _editorPane(p),
                            3 => _gitPane(p),
                            _ => _aiPane(p),
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                if (_message != null)
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    color: (_messageIsError ? p.red : p.green)
                        .withValues(alpha: 0.15),
                    child: Text(
                      _message!,
                      style: ui.copyWith(
                        color: _messageIsError ? p.red : p.green,
                        fontSize: 11,
                      ),
                    ),
                  ),
                _actions(p),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(Palette p) => Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: p.bgAlt,
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Text('设置', style: ui.copyWith(color: p.text)),
            const Spacer(),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _cancel,
                child: Text('✕', style: ui.copyWith(color: p.textDim)),
              ),
            ),
          ],
        ),
      );

  Widget _nav(Palette p) => Container(
        width: 118,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: p.bgAlt,
          border: Border(right: BorderSide(color: p.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, label) in _panes.indexed)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _pane = i),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: _pane == i ? p.bgElev : null,
                      border: Border.all(
                          color: _pane == i ? p.border : Colors.transparent),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      label,
                      style: ui.copyWith(
                          color: _pane == i ? p.text : p.textDim, fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _actions(Palette p) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration:
            BoxDecoration(border: Border(top: BorderSide(color: p.border))),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _button(p, '取消', _cancel),
            const SizedBox(width: 6),
            _button(p, '保存', _save, primary: true),
          ],
        ),
      );

  /* ---------- 通用 ---------- */

  List<Widget> _generalPane(Palette p) => [
        _row(
          p,
          '拉取策略',
          _select(
              p,
              _pullStrategy,
              const {
                'ff-only': '仅快进 (--ff-only)',
                'merge': '合并 (--no-rebase)',
                'rebase': '变基 (--rebase)',
              },
              (v) => setState(() => _pullStrategy = v)),
        ),
        _hint(
            p,
            '「仅快进」还表示推送被拒时跟随 git config（branch.<分支>.rebase → pull.rebase）决定合并还是变基，'
            '与 IDEA 的 Branch default 一致；选合并或变基则固定用它。'),
        _row(
          p,
          '历史每页条数',
          _select(
            p,
            '$_pageSize',
            {
              for (final n in [50, 100, 200, 500]) '$n': '$n'
            },
            (v) => setState(() => _pageSize = int.parse(v)),
          ),
        ),
        _row(
          p,
          '记录操作日志',
          Row(
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _opLog = !_opLog),
                  child: _checkbox(p, _opLog),
                ),
              ),
              const Spacer(),
              _button(p, '打开日志目录', _openLogDir),
            ],
          ),
        ),
        _hint(
            p,
            '记录状态栏的每条消息和 git 报错原文，排查问题用，默认关闭。'
            '写到 ${OpLog.path}，超过 5MB 轮转一次；远端地址里的账号和 Token 会替换成 <REDACTED>。'),
      ];

  Future<void> _openLogDir() async {
    try {
      await Directory(OpLog.dir).create(recursive: true);
      await Git(OpLog.dir).openProject();
    } on GitError catch (e) {
      if (mounted) _report(e.message, isError: true);
    }
  }

  /* ---------- 外观 ---------- */

  List<Widget> _lookPane(Palette p) => [
        _row(
          p,
          '主题',
          _select(
              p, _dark ? 'dark' : 'light', const {'dark': '深色', 'light': '浅色'},
              (v) {
            setState(() => _dark = v == 'dark');
            _preview();
          }),
        ),
        _row(
          p,
          '字号',
          _select(p, '$_fontSize', const {
            '12': '小 (12)',
            '13': '标准 (13)',
            '15': '大 (15)',
          }, (v) {
            setState(() => _fontSize = int.parse(v));
            _preview();
          }),
        ),
        _row(
          p,
          '差异视图',
          _select(
              p,
              _split ? 'split' : 'unified',
              const {
                'split': '并排（含词级高亮）',
                'unified': '统一',
              },
              (v) => setState(() => _split = v == 'split')),
        ),
        _hint(p, '主题和字号立即生效，点「取消」会还原。'),
      ];

  /* ---------- 编辑器 ---------- */

  List<Widget> _editorPane(Palette p) => [
        _row(
          p,
          '默认文本编辑器',
          _select(
            p,
            _chosen.contains(_editor) ? _editor : '',
            {for (final n in _editorOptions) n: n.isEmpty ? '系统默认' : n},
            (v) => setState(() => _editor = v),
          ),
        ),
        _hint(
            p,
            '右键文件 →「编辑文件」用它打开，工具栏「打开项目」没单独设过的项目也用它。'
            '按应用名调用，不依赖 code / subl 这类命令行工具。'),
        if (_editorScanError != null) _hint(p, '扫描本机编辑器失败：$_editorScanError'),
        if (_editorScanError == null && _editorRows.isEmpty)
          _hint(p,
              '没在 /Applications、/System/Applications、~/Applications 里找到已知的编辑器。'),
        for (final name in _editorRows)
          _editorRow(p, name, installed: _installed.contains(name)),
        if (_editorRows.isNotEmpty)
          _hint(p, '只列出本机装了的编辑器。勾上的才会出现在上面的下拉和工具栏「打开项目」的下拉里。'),
      ];

  Widget _editorRow(Palette p, String name, {required bool installed}) {
    final icon = _icons[name];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() {
            if (!_chosen.remove(name)) _chosen.add(name);
          }),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: icon == null ? null : Image.memory(icon),
              ),
              const SizedBox(width: 6),
              // 固定列宽让勾选框紧跟名字，和旧版 150px 的 label 列一致；Expanded 会把它推到最右边。
              SizedBox(
                width: 150,
                child: Text(
                  installed ? name : '$name（已不在本机）',
                  style: ui.copyWith(
                      color: installed ? p.text : p.textDim, fontSize: 12),
                ),
              ),
              _checkbox(p, _chosen.contains(name)),
            ],
          ),
        ),
      ),
    );
  }

  /* ---------- Git 信息 ---------- */

  List<Widget> _gitPane(Palette p) {
    final info = _credential;
    return [
      _sectionTitle(p, '提交身份'),
      _row(p, '用户名 (user.name)', _input(p, _name, hint: '你的名字')),
      _row(p, '邮箱 (user.email)', _input(p, _email, hint: 'you@example.com')),
      _row(
        p,
        '写入全局配置 (--global)',
        Align(
          alignment: Alignment.centerLeft,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _globalIdentity = !_globalIdentity),
              child: _checkbox(p, _globalIdentity),
            ),
          ),
        ),
      ),
      if (widget.git == null) _hint(p, '当前没有打开仓库，身份信息不会被写入。'),
      const SizedBox(height: 10),
      _sectionTitle(p, '远程认证'),
      if (widget.git == null)
        _hint(p, '打开仓库后可查看和切换当前仓库的远程认证账号。')
      else if (info == null)
        _hint(p, '正在读取远程认证…')
      else if (info.transport == 'https') ...[
        _row(p, '推送远端',
            _value(p, '${info.remote} · ${info.host}/${info.repository}')),
        _row(
          p,
          'Git 当前凭据',
          _value(
            p,
            (info.hasCredential
                    ? (info.username.isEmpty ? '未知账号' : info.username)
                    : (info.username.isEmpty ? '未找到凭据' : info.username)) +
                (info.helper.isEmpty ? '' : ' · ${info.helper}'),
          ),
        ),
        _row(p, '远端用户名', _input(p, _username, hint: '例如 Ckales')),
        _row(
          p,
          '访问令牌 (PAT)',
          _input(p, _token,
              obscure: true,
              hint: info.hasCredential
                  ? '••••••••'
                  : '请输入 Personal Access Token'),
        ),
        _hint(
            p, '新令牌通过 Git credential helper 写入系统钥匙串，CGit 不保存；不修改凭据时可留空并直接测试。'),
        _testRow(p, '保存凭据并测试', _credentialBusy ? null : _credentialAction,
            _credentialResult, _credentialFailed),
      ] else if (info.transport == 'ssh')
        _hint(p, '当前远端使用 SSH，认证由系统 SSH Key 和 ~/.ssh/config 管理。')
      else
        _hint(p,
            '当前远端使用 ${info.transport.isEmpty ? '未知' : info.transport} 协议，CGit 不保存该协议的凭据。'),
    ];
  }

  /* ---------- AI ---------- */

  List<Widget> _aiPane(Palette p) => [
        _row(p, '请求地址', _input(p, _aiUrl, hint: 'https://api.openai.com/v1')),
        _row(
          p,
          '令牌',
          _input(p, _aiToken,
              obscure: true, hint: _aiTokenStored ? '已保存，留空则不变' : 'sk-…'),
        ),
        _row(p, '模型', _input(p, _aiModel, hint: 'gpt-4o-mini')),
        _wideRow(
          p,
          '提示词',
          SizedBox(
            height: 130,
            child: TextField(
              controller: _aiPrompt,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: ui.copyWith(color: p.text, fontSize: 12),
              cursorColor: p.accent,
              decoration: _inputDecoration(p, null),
            ),
          ),
        ),
        _hint(
            p,
            '兼容 OpenAI 的 /chat/completions 接口。填基址即可，会自动补 /chat/completions。'
            '配置好后点提交按钮左边的 ✦ 图标，用已暂存的 diff 生成提交说明。'),
        _hint(p, '令牌保存在本机应用偏好中，生成时会把暂存区 diff 发送到上面的地址。'),
        _testRow(p, '测试', _aiBusy ? null : _testAi, _aiResult, _aiFailed),
      ];

  /* ---------- shared bits ---------- */

  Widget _sectionTitle(Palette p, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: ui.copyWith(color: p.textDim, fontSize: 11)),
      );

  Widget _hint(Palette p, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: ui.copyWith(color: p.textDim, fontSize: 11, height: 1.45)),
      );

  Widget _row(Palette p, String label, Widget control) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            SizedBox(
              width: 132,
              child:
                  Text(label, style: ui.copyWith(color: p.text, fontSize: 12)),
            ),
            Expanded(child: control),
          ],
        ),
      );

  /// Label above the control — for anything too tall for the two-column row.
  Widget _wideRow(Palette p, String label, Widget control) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child:
                  Text(label, style: ui.copyWith(color: p.text, fontSize: 12)),
            ),
            control,
          ],
        ),
      );

  Widget _value(Palette p, String text) =>
      Text(text, style: ui.copyWith(color: p.textDim, fontSize: 12));

  /// A picker that looks like the text fields beside it and opens the app's own
  /// menu.
  ///
  /// Not `DropdownButton`: its popup is a Material menu with 48px rows and its
  /// own surface colour, which lands in the middle of this UI looking like it
  /// came from another app. Every other menu here already goes through
  /// [showRepoMenu], so this one does too.
  Widget _select(
    Palette p,
    String value,
    Map<String, String> options,
    void Function(String) onChanged,
  ) =>
      _PickerField(
        label: options[value] ?? value,
        palette: p,
        onTapAt: (pos) => showRepoMenu(
          context: context,
          position: pos,
          items: [
            for (final e in options.entries)
              MenuAction(e.value, () => onChanged(e.key),
                  checked: e.key == value),
          ],
        ),
      );

  InputDecoration _inputDecoration(Palette p, String? hint) => InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        hintText: hint,
        hintStyle: ui.copyWith(color: p.textDim, fontSize: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.border),
        ),
      );

  Widget _input(
    Palette p,
    TextEditingController controller, {
    bool obscure = false,
    String? hint,
  }) =>
      SizedBox(
        height: 26,
        child: TextField(
          controller: controller,
          obscureText: obscure,
          style: ui.copyWith(color: p.text, fontSize: 12),
          cursorColor: p.accent,
          decoration: _inputDecoration(p, hint),
        ),
      );

  Widget _checkbox(Palette p, bool value) => Container(
        width: 13,
        height: 13,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: value ? p.accent : p.bg,
          border: Border.all(color: value ? p.accent : p.border),
          borderRadius: BorderRadius.circular(3),
        ),
        child: value
            ? const Text('✓',
                style:
                    TextStyle(fontSize: 9, color: Color(0xFFFFFFFF), height: 1))
            : null,
      );

  Widget _testRow(
    Palette p,
    String label,
    VoidCallback? onTap,
    String result,
    bool failed,
  ) =>
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _button(p, label, onTap),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                result,
                style: ui.copyWith(
                  color:
                      result.isEmpty ? p.textDim : (failed ? p.red : p.green),
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
          ],
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
                fontSize: 12,
                color: onTap == null
                    ? p.textDim
                    : (primary ? const Color(0xFFFFFFFF) : p.text),
              ),
            ),
          ),
        ),
      );
}

/// The control half of [_SettingsSheetState._select]: a field-shaped button
/// with a chevron, styled to match the text inputs it sits next to.
class _PickerField extends StatefulWidget {
  const _PickerField({
    required this.label,
    required this.palette,
    required this.onTapAt,
  });

  final String label;
  final Palette palette;
  final void Function(Offset position) onTapAt;

  @override
  State<_PickerField> createState() => _PickerFieldState();
}

class _PickerFieldState extends State<_PickerField> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapUp: (_) => widget.onTapAt(menuAnchorBelow(context)),
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hover ? p.bgHover : p.bgElev,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.copyWith(color: p.text, fontSize: 12),
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
