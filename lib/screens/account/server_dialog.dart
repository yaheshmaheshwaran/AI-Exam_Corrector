import 'package:flutter/material.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/accounts/supabase_account_repository.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// Checks that a server answers; the real one asks it over the network.
typedef ServerProbe = Future<void> Function(ServerConfig server);

/// Where the college server is: its address and public key, from the
/// college admin (or the Supabase project's API settings).
class ServerDialog extends StatefulWidget {
  const ServerDialog({super.key, required this.session, this.probe = SupabaseAccountRepository.check});

  final AppSession session;
  final ServerProbe probe;

  /// True once a server was saved.
  static Future<bool> show(BuildContext context, AppSession session, {ServerProbe? probe}) async =>
      await showAppDialog<bool>(
        context: context,
        builder: (BuildContext context) =>
            ServerDialog(session: session, probe: probe ?? SupabaseAccountRepository.check),
      ) ??
      false;

  @override
  State<ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<ServerDialog> {
  late final TextEditingController _url = TextEditingController(text: widget.session.server?.url ?? '');
  late final TextEditingController _key = TextEditingController(text: widget.session.server?.anonKey ?? '');
  String? _error;
  String? _ok;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  ServerConfig? _read() {
    try {
      return ServerConfig.validated(url: _url.text, anonKey: _key.text);
    } on AccountException catch (error) {
      setState(() {
        _error = error.message;
        _ok = null;
      });
      return null;
    }
  }

  Future<void> _test() async {
    final ServerConfig? server = _read();
    if (server == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await widget.probe(server);
      if (mounted) setState(() => _ok = 'Connected — ${server.host} is ready for Marklume.');
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final ServerConfig? server = _read();
    if (server == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.connect(server);
      if (mounted) Navigator.of(context).pop(true);
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? error = _error;
    final String? ok = _ok;
    return AlertDialog(
      title: const Text('College server'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Accounts and published results are kept on your college’s server. '
              'Your college admin gives you its address and public key.',
              style: context.text.caption,
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('server-url'),
              controller: _url,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://abcd.supabase.co'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('server-key'),
              controller: _key,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Public key (anon)', hintText: 'eyJhbGciOi…'),
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 12),
              InfoBanner(title: error, tone: ToneKind.danger, margin: EdgeInsets.zero),
            ],
            if (ok != null) ...<Widget>[
              const SizedBox(height: 12),
              InfoBanner(title: ok, tone: ToneKind.success, margin: EdgeInsets.zero),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('server-test'),
          onPressed: _busy ? null : _test,
          child: const Text('Test connection'),
        ),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(key: const Key('server-save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
