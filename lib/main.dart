import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
// Using manual token input only (no OAuth)

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Discord DM Cleaner',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(primary: Colors.indigoAccent),
      ),
      home: const LoginScreen(),
    );
  }
}

class DiscordApiClient {
  final String token;
  final Map<String, String> headers;
  static const base = 'https://discord.com/api/v9';

  DiscordApiClient(this.token)
      : headers = {
        'Authorization': token,
          'Content-Type': 'application/json',
          'User-Agent':
              'DiscordDMCleaner/1.0 (https://example.local, v0.1) Flutter'
        };

  Future<Map<String, dynamic>?> validateToken() async {
    final r = await http.get(Uri.parse('$base/users/@me'), headers: headers);
    if (r.statusCode == 200) return jsonDecode(r.body);
    return null;
  }

  Future<List<dynamic>> fetchDms() async {
    final r = await http.get(Uri.parse('$base/users/@me/channels'), headers: headers);
    if (r.statusCode == 200) return jsonDecode(r.body) as List<dynamic>;
    return [];
  }

  Future<List<dynamic>> getMessages(String channelId, {int limit = 50, String? before}) async {
    final uri = Uri.parse('$base/channels/$channelId/messages')
      .replace(queryParameters: {if (limit != 50) 'limit': limit.toString(), if (before != null) 'before': before});
    final r = await http.get(uri, headers: headers);
    if (r.statusCode == 200) return jsonDecode(r.body) as List<dynamic>;
    if (r.statusCode == 429) {
      final body = jsonDecode(r.body);
      final wait = (body['retry_after'] ?? 1).toDouble();
      await Future.delayed(Duration(milliseconds: (wait * 1000).toInt()));
      return getMessages(channelId, limit: limit, before: before);
    }
    return [];
  }

  Future<bool> deleteMessage(String channelId, String messageId) async {
    final r = await http.delete(Uri.parse('$base/channels/$channelId/messages/$messageId'), headers: headers);
    if (r.statusCode == 204) return true;
    if (r.statusCode == 429) {
      final body = jsonDecode(r.body);
      final wait = (body['retry_after'] ?? 1).toDouble();
      await Future.delayed(Duration(milliseconds: (wait * 1000).toInt()));
      return deleteMessage(channelId, messageId);
    }
    return false;
  }

  // Lower-level delete that returns the raw HTTP response (no retry logic).
  Future<http.Response> deleteMessageRaw(String channelId, String messageId) async {
    return await http.delete(Uri.parse('$base/channels/$channelId/messages/$messageId'), headers: headers);
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _tokenCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  // OAuth helpers removed — app uses manual token input only.

  void _login() async {
    String token = _tokenCtrl.text.trim();
    // Accept tokens wrapped in single/double/backtick quotes; strip them.
    if (token.length >= 2) {
      final first = token.codeUnitAt(0);
      final last = token.codeUnitAt(token.length - 1);
      if ((first == 0x27 && last == 0x27) || // '\''
          (first == 0x22 && last == 0x22) || // '"'
          (first == 0x60 && last == 0x60)) { // '`'
        token = token.substring(1, token.length - 1).trim();
      }
    }
    if (token.isEmpty) {
      setState(() => _error = 'Please enter a token');
      return;
    }

    // Accept common pasted formats like: "Authorization: <token>"
    final lower = token.toLowerCase();
    if (lower.startsWith('authorization:')) {
      token = token.substring('authorization:'.length).trim();
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final api = DiscordApiClient(token);
    try {
      final user = await api.validateToken();
      if (user == null) {
        setState(() {
          _error = 'Invalid token';
          _loading = false;
        });
        return;
      }

      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DMListScreen(api: api, currentUser: user)));
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Discord DM Cleaner')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _tokenCtrl,
              decoration: const InputDecoration(labelText: 'Discord Token'),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            _loading
                ? const CircularProgressIndicator()
                : ElevatedButton(onPressed: _login, child: const Text('Login'))
          ],
        ),
      ),
    );
  }
}

class DMListScreen extends StatefulWidget {
  final DiscordApiClient api;
  final Map<String, dynamic> currentUser;

  const DMListScreen({Key? key, required this.api, required this.currentUser}) : super(key: key);

  @override
  State<DMListScreen> createState() => _DMListScreenState();
}

class _DMListScreenState extends State<DMListScreen> {
  List<dynamic> _dms = [];
  Set<String> _selected = {};
  bool _loading = true;
  final List<String> _logs = [];
  bool _processing = false;
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    _loadDms();
  }

  void _addLog(String s) {
    setState(() {
      _logs.insert(0, s);
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  Future<void> _loadDms() async {
    setState(() => _loading = true);
      try {
      final raw = await widget.api.fetchDms();
      // Normalize display name + avatar similar to python version
      final processed = raw.map((channel) {
        final t = Map<String, dynamic>.from(channel as Map);
        final type = t['type'] ?? 0;
        String name = 'Unknown';
        String subtitle = '';
        String? avatar;
        if (type == 1) {
          final recipients = t['recipients'] as List<dynamic>? ?? [];
          if (recipients.isNotEmpty) {
            final u = Map<String, dynamic>.from(recipients[0]);
            name = u['global_name'] ?? u['username'] ?? 'Unknown';
            // Prefer the actual username as the secondary line (handle)
            subtitle = u['username']?.toString() ?? '';
            if (u['avatar'] != null) {
              avatar = 'https://cdn.discordapp.com/avatars/${u['id']}/${u['avatar']}.png'.replaceAll(' ', '');
            }
          }
        } else if (type == 3) {
          name = t['name'] ?? 'Group';
          subtitle = 'Group DM';
          if (t['icon'] != null) {
            avatar = 'https://cdn.discordapp.com/channel-icons/${t['id']}/${t['icon']}.png'.replaceAll(' ', '');
          }
        }
        t['processed_name'] = name;
        t['processed_subtitle'] = subtitle.isNotEmpty ? subtitle : name;
        t['processed_avatar'] = avatar;
        return t;
      }).toList();

      setState(() {
        _dms = processed;
      });
      _addLog('Loaded ${_dms.length} DMs');
    } catch (e) {
      _addLog('Error loading DMs: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) {
      _addLog('No channels selected for deletion');
      return;
    }
    _cancelRequested = false;
    setState(() => _processing = true);
    final myId = widget.currentUser['id'];
    final myName = widget.currentUser['global_name'] ?? widget.currentUser['username'] ?? myId;
    final targets = List<String>.from(_selected);
    _addLog('Starting deletion for ${targets.length} channel(s)');
    for (var i = 0; i < targets.length; i++) {
      if (_cancelRequested) {
        _addLog('Stop requested. Ending operation.');
        break;
      }
      final cid = targets[i];
      final dmInfo = _dms.cast<Map<String, dynamic>>().firstWhere(
        (d) => d['id'] == cid,
        orElse: () => <String, dynamic>{},
          );
      final display = (dmInfo['processed_name'] ?? cid).toString();
      _addLog('Processing chat with $display (${i + 1}/${targets.length})');
      String? before;
      bool hasMore = true;
      while (hasMore) {
        if (_cancelRequested) {
          _addLog('Stop requested. Ending operation.');
          hasMore = false;
          break;
        }
        List<dynamic> messages = [];
        try {
          messages = await widget.api.getMessages(cid, limit: 50, before: before);
          _addLog('Fetched ${messages.length} messages from $display');
        } catch (e) {
          _addLog('Error fetching messages for $display: $e');
          break;
        }
        if (messages.isEmpty) break;
        final myMessages = messages
            .where((m) => (m['author']?['id'] ?? '') == myId && _isUserDeletableMessage(m))
            .toList();
        final skippedSystem = messages.where((m) => (m['author']?['id'] ?? '') == myId && !_isUserDeletableMessage(m)).length;
        _addLog('Found ${myMessages.length} of my messages to delete in $display (skipped ${skippedSystem} system/unsupported)');
        if (myMessages.isEmpty) {
          before = messages.last['id'];
          continue;
        }
        for (final m in myMessages) {
          if (_cancelRequested) {
            _addLog('Stop requested. Ending operation.');
            hasMore = false;
            break;
          }
          try {
            final content = (m['content'] ?? '').toString();
            String snippet = content.trim();
            if (snippet.length > 120) snippet = snippet.substring(0, 117) + '...';
            // message is already filtered to myId; display myName
            http.Response resp = await widget.api.deleteMessageRaw(cid, m['id']);
            // handle 429 retries
            while (resp.statusCode == 429) {
              if (_cancelRequested) {
                _addLog('Stop requested. Ending operation.');
                hasMore = false;
                break;
              }
              try {
                final body = jsonDecode(resp.body);
                final wait = (body['retry_after'] ?? 1).toDouble();
                _addLog('Rate limited when deleting message; waiting ${wait}s');
                await Future.delayed(Duration(milliseconds: (wait * 1000).toInt()));
              } catch (_) {
                await Future.delayed(const Duration(milliseconds: 1000));
              }
              resp = await widget.api.deleteMessageRaw(cid, m['id']);
            }

            if (_cancelRequested) {
              _addLog('Stop requested. Ending operation.');
              hasMore = false;
              break;
            }

            if (resp.statusCode == 204) {
              _addLog('Deleted my message as $myName in chat with $display: "${snippet}"');
            } else {
              String bodyStr = '';
              try {
                bodyStr = resp.body ?? '';
              } catch (_) {}
              _addLog('Failed to delete my message as $myName in chat with $display: status=${resp.statusCode} body=${bodyStr}');
            }
          } catch (e) {
            _addLog('Exception deleting message in $display: $e');
          }
          await Future.delayed(const Duration(milliseconds: 800));
        }
        if (_cancelRequested) break;
        before = messages.last['id'];
      }
    }
    setState(() => _processing = false);
    _addLog(_cancelRequested ? 'Operation stopped' : 'Operation finished');
    await _loadDms();
  }

  bool _isDeletable(dynamic msg) {
    final content = (msg['content'] ?? '').toString();
    final type = msg['type'] ?? 0;
    final isPoll = (msg['embeds'] ?? []).isNotEmpty || content.toLowerCase().contains('vote');
    if (type != 0 && type != 19 && !isPoll) return false;
    if (type == 0 && content.trim().isEmpty && (msg['attachments'] ?? []).isEmpty && (msg['sticker_items'] ?? []).isEmpty && !isPoll) return false;
    final callKeywords = ['started a call', 'missed call', 'ongoing call', 'incoming call'];
    if (callKeywords.any((k) => content.toLowerCase().contains(k))) return false;
    return true;
  }

  bool _isUserDeletableMessage(dynamic msg) {
    // Avoid attempting to delete Discord system/unsupported message types.
    // Common deletable user-generated types: 0 (DEFAULT), 19 (REPLY)
    final type = msg is Map ? (msg['type'] ?? 0) : 0;
    return type == 0 || type == 19;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DMs'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadDms),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _dms.isEmpty
                    ? const Center(child: Text('No DMs found'))
                    : ListView.builder(
                        itemCount: _dms.length,
                        itemBuilder: (context, index) {
                          final dm = _dms[index] as Map<String, dynamic>;
                          final id = dm['id'] as String;
                          final name = dm['processed_name'] as String? ?? 'Unknown';
                          final subtitle = dm['processed_subtitle'] as String? ?? name;
                          final avatar = dm['processed_avatar'] as String?;
                          return CheckboxListTile(
                            value: _selected.contains(id),
                            onChanged: (v) {
                              setState(() {
                                if (v == true) _selected.add(id);
                                else _selected.remove(id);
                              });
                            },
                            title: Text(name),
                            subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
                            secondary: avatar != null
                                ? CircleAvatar(backgroundImage: NetworkImage(avatar))
                                : const CircleAvatar(child: Icon(Icons.person)),
                          );
                        },
                      ),
          ),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _processing ? null : _deleteSelected,
                  child: _processing ? const Text('Processing...') : const Text('Delete Selected'),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _processing
                    ? () {
                        setState(() => _cancelRequested = true);
                        _addLog('Stop requested by user');
                      }
                    : null,
                child: const Text('Stop'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _processing
                    ? null
                    : () {
                        setState(() {
                          if (_selected.length == _dms.length) _selected.clear();
                          else _selected = _dms.map((d) => d['id'] as String).toSet();
                        });
                      },
                child: const Text('Toggle All'),
              ),
            ],
          ),
          const Divider(),
          SizedBox(
            height: 120,
            child: ListView.builder(
              reverse: true,
              itemCount: _logs.length,
              itemBuilder: (c, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(_logs[i], style: const TextStyle(fontSize: 12)),
              ),
            ),
          )
        ],
      ),
    );
  }
}
