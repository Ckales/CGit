import 'package:flutter/material.dart';

import 'ai_settings.dart';
import 'git.dart';
import 'git_text.dart';
import 'theme.dart';

/// Settings: git identity, remote credentials, and the AI endpoint.
///
/// The token field is deliberately write-only. Core never returns a stored
/// credential — [GitCredentialInfo] reports whether one exists, not what it is
/// — so there is nothing to prefill, and an empty field means "keep what is
/// already saved" rather than "clear it".
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.git,
    required this.ai,
    required this.onClose,
  });

  final Git git;
  final AiSettings? ai;
  final VoidCallback onClose;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _token = TextEditingController();
  final _aiUrl = TextEditingController();
  final _aiModel = TextEditingController();
  final _aiToken = TextEditingController();

  GitCredentialInfo? _credential;
  bool _globalIdentity = false;
  bool _busy = false;
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
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAll() async {
    try {
      final identity = await widget.git.identity();
      final credential = await widget.git.credential();
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

    final ai = widget.ai;
    if (ai != null && mounted) {
      setState(() {
        _aiUrl.text = ai.baseUrl;
        _aiModel.text = ai.model;
      });
      // The AI token is ours to hold, so it can be shown as "already set"
      // without revealing it: the field stays empty and the hint changes.
      final has = await ai.readToken() != null;
      if (mounted) setState(() => _aiTokenStored = has);
    }
  }

  bool _aiTokenStored = false;

  void _report(String text, {bool isError = false}) => setState(() {
        _message = text;
        _messageIsError = isError;
      });

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final ok = await action();
      if (ok != null && mounted) _report(ok);
    } on GitError catch (e) {
      if (mounted) _report(e.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveIdentity() => _run(() async {
        await widget.git.setIdentity(
          _name.text.trim(),
          _email.text.trim(),
          global: _globalIdentity,
        );
        return _globalIdentity ? '已保存到全局 git 配置' : '已保存到本仓库配置';
      });

  /// One button for the whole credential flow, because the useful action
  /// depends on what is already stored — the same rule the Tauri app uses.
  Future<void> _credentialAction() {
    final action = credentialAction(
      hasCredential: _credential?.hasCredential ?? false,
      infoUsername: _credential?.username,
      username: _username.text,
      token: _token.text,
    );

    return switch (action) {
      'missing-username' => _run(() async => throw GitError('请先填写用户名')),
      'missing-token' => _run(() async => throw GitError('该用户名还没有保存的凭据，请填写令牌')),
      'save-and-test' => _run(() async {
          final info = await widget.git.saveCredential(
            _username.text.trim(),
            _token.text,
          );
          // Clear immediately: the token has reached git's helper and this app
          // has no reason to keep holding it.
          _token.clear();
          setState(() => _credential = info);
          return await widget.git.testCredential();
        }),
      _ => _run(() => widget.git.testCredential()),
    };
  }

  Future<void> _saveAi() => _run(() async {
        final ai = widget.ai;
        if (ai == null) throw GitError('AI 设置尚未加载');
        await ai.setBaseUrl(_aiUrl.text);
        await ai.setModel(_aiModel.text);
        if (_aiToken.text.trim().isNotEmpty) {
          await ai.writeToken(_aiToken.text);
          _aiToken.clear();
          setState(() => _aiTokenStored = true);
        }
        return 'AI 设置已保存';
      });

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final info = _credential;

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Container(
            width: 620,
            height: 620,
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
                      Text('设置', style: ui.copyWith(color: p.text)),
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
                  child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      _group(p, 'Git 身份', [
                        _field(p, '名字', _name),
                        _field(p, '邮箱', _email),
                        Row(
                          children: [
                            _check(p, '写入全局配置', _globalIdentity,
                                (v) => setState(() => _globalIdentity = v)),
                            const Spacer(),
                            _button(p, '保存身份', _busy ? null : _saveIdentity),
                          ],
                        ),
                      ]),
                      _group(p, '远程认证', [
                        if (info != null)
                          Text(
                            '${info.transport} · ${info.host}/${info.repository}'
                            '${info.helper.isEmpty ? '' : ' · helper: ${info.helper}'}',
                            style: ui.copyWith(color: p.textDim, fontSize: 11),
                          ),
                        _field(p, '用户名', _username),
                        _field(
                          p,
                          '令牌',
                          _token,
                          obscure: true,
                          // Never prefilled: core does not hand back stored
                          // credentials, and this app does not keep a copy.
                          hint: (info?.hasCredential ?? false)
                              ? '已保存凭据，留空则仅测试'
                              : '粘贴访问令牌',
                        ),
                        Row(
                          children: [
                            Text(
                              (info?.hasCredential ?? false)
                                  ? '已有凭据（${info!.username}）'
                                  : '尚未保存凭据',
                              style: ui.copyWith(color: p.textDim, fontSize: 11),
                            ),
                            const Spacer(),
                            _button(p, '保存并测试',
                                _busy ? null : _credentialAction),
                          ],
                        ),
                      ]),
                      _group(p, 'AI 提交说明', [
                        _field(p, '请求地址', _aiUrl,
                            hint: 'https://api.openai.com/v1'),
                        _field(p, '模型', _aiModel, hint: 'gpt-4o-mini'),
                        _field(
                          p,
                          '令牌',
                          _aiToken,
                          obscure: true,
                          hint: _aiTokenStored ? '已保存在钥匙串，留空则不变' : '粘贴 API Key',
                        ),
                        Row(
                          children: [
                            Text('令牌保存在系统钥匙串，不写入偏好文件',
                                style:
                                    ui.copyWith(color: p.textDim, fontSize: 11)),
                            const Spacer(),
                            _button(p, '保存 AI 设置', _busy ? null : _saveAi),
                          ],
                        ),
                      ]),
                    ],
                  ),
                ),
                if (_message != null)
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _group(Palette p, String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(title,
                  style: ui.copyWith(color: p.textDim, fontSize: 11)),
            ),
            for (final c in children)
              Padding(padding: const EdgeInsets.only(bottom: 6), child: c),
          ],
        ),
      );

  Widget _field(
    Palette p,
    String label,
    TextEditingController controller, {
    bool obscure = false,
    String? hint,
  }) =>
      Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: ui.copyWith(color: p.text, fontSize: 12)),
          ),
          Expanded(
            child: SizedBox(
              height: 26,
              child: TextField(
                controller: controller,
                obscureText: obscure,
                style: ui.copyWith(color: p.text, fontSize: 12),
                cursorColor: p.accent,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
                ),
              ),
            ),
          ),
        ],
      );

  Widget _check(
    Palette p,
    String label,
    bool value,
    void Function(bool) onChanged,
  ) =>
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onChanged(!value),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
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
                        style: TextStyle(
                            fontSize: 9,
                            color: Color(0xFFFFFFFF),
                            height: 1))
                    : null,
              ),
              const SizedBox(width: 5),
              Text(label, style: ui.copyWith(color: p.text, fontSize: 11)),
            ],
          ),
        ),
      );

  Widget _button(Palette p, String label, VoidCallback? onTap) => MouseRegion(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: onTap == null ? p.bgElev : p.accent,
              border: Border.all(color: onTap == null ? p.border : p.accent),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              label,
              style: ui.copyWith(
                fontSize: 12,
                color: onTap == null ? p.textDim : const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      );
}
