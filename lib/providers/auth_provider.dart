import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/xtream_api_service.dart';

class AuthProvider extends ChangeNotifier {
  static const _serverUrlKey = 'server_url';
  static const _usernameKey = 'username';
  static const _passwordKey = 'password';

  String? _serverUrl;
  String? _username;
  String? _password;
  bool _isLoading = false;

  String? get serverUrl => _serverUrl;
  String? get username => _username;
  String? get password => _password;
  bool get isLoading => _isLoading;
  bool get isLoggedIn =>
      (_serverUrl?.isNotEmpty ?? false) &&
      (_username?.isNotEmpty ?? false) &&
      (_password?.isNotEmpty ?? false);

  Future<void> loadSavedLogin() async {
    _setLoading(true);
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_serverUrlKey);
    _username = prefs.getString(_usernameKey);
    _password = prefs.getString(_passwordKey);
    _setLoading(false);
  }

  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _setLoading(true);
    final normalizedUrl = XtreamApiService.normalizeServerUrl(serverUrl);
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_serverUrlKey, normalizedUrl);
    await prefs.setString(_usernameKey, username.trim());
    await prefs.setString(_passwordKey, password);

    _serverUrl = normalizedUrl;
    _username = username.trim();
    _password = password;
    _setLoading(false);
  }

  Future<void> logout() async {
    _setLoading(true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverUrlKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_passwordKey);

    _serverUrl = null;
    _username = null;
    _password = null;
    _setLoading(false);
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }
}
