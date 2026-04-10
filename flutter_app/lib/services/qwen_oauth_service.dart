import 'dart:convert';
import 'native_bridge.dart';

/// Manages Qwen OAuth token sharing between Termux and ClawHub.
///
/// When the user configures Qwen OAuth via `qwen auth` in Termux,
/// the token is saved to `~/.archclaw/qwen-oauth.json`.
///
/// This service reads that token and injects it into the proot environment
/// so that clawhub, zeroclaw, and other AI tools can use it.
class QwenOAuthService {
  static const _termuxTokenPath = '/root/.openclaw/qwen-oauth-termux.json';

  /// Read the Qwen OAuth token from Termux home directory.
  /// Returns the parsed token object, or null if not found/expired.
  static Future<Map<String, dynamic>?> getToken() async {
    try {
      final json = await NativeBridge.getQwenOAuthToken();
      if (json == null || json.isEmpty) return null;

      final data = jsonDecode(json) as Map<String, dynamic>;
      final expiresAt = data['expires_at'] as int? ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Check if token is still valid
      if (expiresAt > now) {
        return data;
      }
      return null; // Expired
    } catch (_) {
      return null;
    }
  }

  /// Check if a valid Qwen OAuth token exists in Termux.
  static Future<bool> hasValidToken() async {
    final token = await getToken();
    return token != null && token['access_token'] != null;
  }

  /// Inject the Qwen OAuth token into the proot environment.
  /// Writes the token to a file inside the rootfs that AI tools can read.
  /// Returns true if the token was successfully injected.
  static Future<bool> injectIntoProot() async {
    try {
      final token = await getToken();
      if (token == null) return false;

      final json = const JsonEncoder.withIndent('  ').convert(token);

      // Write to rootfs where openclaw/zeroclaw can find it
      await NativeBridge.writeRootfsFile(_termuxTokenPath, json);

      // Also set environment variables for tools that read them
      await NativeBridge.runInProot(
        'mkdir -p /root/.openclaw && '
        'cat > /root/.openclaw/qwen-oauth.env <<EOF\n'
        'QWEN_ACCESS_TOKEN=${token['access_token']}\n'
        'QWEN_MODEL=${token['model'] ?? 'qwen3-coder-plus'}\n'
        'EOF',
        timeout: 10,
      );

      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get the Qwen OAuth access token string (if valid).
  static Future<String?> getAccessToken() async {
    final token = await getToken();
    return token?['access_token'] as String?;
  }

  /// Get token info for display in UI.
  static Future<Map<String, String>?> getTokenInfo() async {
    final token = await getToken();
    if (token == null) return null;

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      (token['expires_at'] as int) * 1000,
    );
    final scope = token['scope'] as String? ?? 'qwen-code-api';
    final now = DateTime.now();
    final remaining = expiresAt.difference(now);

    return {
      'scope': scope,
      'expires': expiresAt.toLocal().toString(),
      'remaining': remaining.inHours > 0
          ? '${remaining.inHours}h ${remaining.inMinutes % 60}m'
          : '${remaining.inMinutes}m',
    };
  }
}
