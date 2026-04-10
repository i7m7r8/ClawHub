import 'dart:convert';
import 'native_bridge.dart';

/// Manages Qwen OAuth token sharing between Termux and ClawHub.
///
/// When the user configures Qwen Code OAuth in Termux,
/// the token is saved to `~/.qwen/oauth_creds.json`.
///
/// This service reads that token and injects it into the proot environment
/// so that openclaw, zeroclaw, and other AI tools can use it.
class QwenOAuthService {
  static const _termuxTokenPath = '/root/.qwen/oauth_creds.json';

  /// Read the Qwen OAuth token from Termux home directory.
  /// Returns the parsed token object, or null if not found/expired.
  ///
  /// Actual JSON structure from `~/.qwen/oauth_creds.json`:
  /// {
  ///   "access_token": "...",
  ///   "token_type": "Bearer",
  ///   "refresh_token": "...",
  ///   "resource_url": "portal.qwen.ai",
  ///   "expiry_date": 1775807337002  // MILLISECONDS
  /// }
  static Future<Map<String, dynamic>?> getToken() async {
    try {
      final json = await NativeBridge.getQwenOAuthToken();
      if (json == null || json.isEmpty) return null;

      final data = jsonDecode(json) as Map<String, dynamic>;

      // expiry_date is in MILLISECONDS (not seconds)
      final expiryDate = data['expiry_date'] as int? ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      if (expiryDate > now) {
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
  static Future<bool> injectIntoProot() async {
    try {
      final token = await getToken();
      if (token == null) return false;

      final json = const JsonEncoder.withIndent('  ').convert(token);
      await NativeBridge.writeRootfsFile(_termuxTokenPath, json);

      // Set environment variables for tools that read them
      await NativeBridge.runInProot(
        'mkdir -p /root/.openclaw && '
        'cat > /root/.openclaw/qwen-oauth.env <<EOF\n'
        'QWEN_ACCESS_TOKEN=${token['access_token']}\n'
        'QWEN_MODEL=qwen3-coder-plus\n'
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
      token['expiry_date'] as int,
    );
    final resourceUrl = token['resource_url'] as String? ?? 'portal.qwen.ai';
    final now = DateTime.now();
    final remaining = expiresAt.difference(now);

    return {
      'resource_url': resourceUrl,
      'expires': expiresAt.toLocal().toString(),
      'remaining': remaining.inHours > 0
          ? '${remaining.inHours}h ${remaining.inMinutes % 60}m'
          : '${remaining.inMinutes}m',
    };
  }
}
