import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/xtream_api_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _submitted = false;

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return FScaffold(
      childPad: false,
      child: ColoredBox(
        color: context.theme.colors.background,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: FCard.raw(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'IPTV Player',
                        style: context.theme.typography.xl2.copyWith(
                          color: context.theme.colors.foreground,
                          fontWeight: FontWeight.w800,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Unesi Xtream login podatke',
                        style: context.theme.typography.sm.copyWith(
                          color: context.theme.colors.mutedForeground,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 26),
                      FTextField(
                        control: FTextFieldControl.managed(
                          controller: _serverController,
                        ),
                        label: const Text('Server URL'),
                        hint: 'http://example.com:8080',
                        textInputAction: TextInputAction.next,
                        error: _errorFor(_serverController.text),
                      ),
                      const SizedBox(height: 14),
                      FTextField(
                        control: FTextFieldControl.managed(
                          controller: _usernameController,
                        ),
                        label: const Text('Username'),
                        textInputAction: TextInputAction.next,
                        error: _errorFor(_usernameController.text),
                      ),
                      const SizedBox(height: 14),
                      FTextField.password(
                        control: FTextFieldControl.managed(
                          controller: _passwordController,
                        ),
                        label: const Text('Password'),
                        onSubmit: (_) => _submit(),
                        error: _errorFor(_passwordController.text),
                      ),
                      const SizedBox(height: 22),
                      FButton(
                        onPress: auth.isLoading ? null : _submit,
                        prefix: auth.isLoading
                            ? const SizedBox.square(
                                dimension: 16,
                                child: FCircularProgress(),
                              )
                            : const Icon(FLucideIcons.logIn, size: 18),
                        child: Text(auth.isLoading ? 'Prijava...' : 'Login'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _errorFor(String value) {
    if (!_submitted || value.trim().isNotEmpty) {
      return null;
    }
    return const Text('Polje je obavezno');
  }

  Future<void> _submit() async {
    setState(() => _submitted = true);

    if (_serverController.text.trim().isEmpty ||
        _usernameController.text.trim().isEmpty ||
        _passwordController.text.trim().isEmpty) {
      return;
    }

    await context.read<AuthProvider>().login(
          serverUrl: XtreamApiService.normalizeServerUrl(
            _serverController.text,
          ),
          username: _usernameController.text,
          password: _passwordController.text,
        );
  }
}
