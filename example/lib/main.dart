import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chafon_h906_rfid/chafon_h906_rfid.dart';

void main() {
  runApp(const MaterialApp(home: H906DemoPage()));
}

class H906DemoPage extends StatefulWidget {
  const H906DemoPage({super.key});

  @override
  State<H906DemoPage> createState() => _H906DemoPageState();
}

class _H906DemoPageState extends State<H906DemoPage> {
  final _plugin = ChafonH906Rfid();
  bool _busy = false;
  bool _connected = false;
  String _status = 'Disconnected';
  int? _baud;
  int? _lastCode;

  // Power UI state
  int _power = 30; // 0..33 dBm
  Map<String, dynamic>? _lastSetPowerResp;

  // SINGLE READ state
  final _epcCtrl = TextEditingController(); // optional EPC filter (hex)
  final _pwdCtrl = TextEditingController(text: '00000000');
  int _wordPtrSR = 2;
  int _lenSR = 6;
  Map<String, dynamic>? _lastReadResp;
  String? _lastHex;

  // INVENTORY state
  bool _invRunning = false;
  Map<String, dynamic>? _lastInvResp;
  int _session = 0;
  int _qValue = 4;
  bool _includeTid = false;

  // Native -> Dart callbacks via plugin streams
  StreamSubscription<Map<String, dynamic>>? _tagSub;

  final List<Map<String, dynamic>> _tags = [];
  final Set<String> _seen = {};

  @override
  void initState() {
    super.initState();

    // Subscribe to plugin streams (onTag & onInventoryStopped)
    _tagSub = _plugin.onTag.listen((m) {
      final epc = (m['epc'] ?? '') as String;
      if (epc.isEmpty) return;
      if (!mounted) return;
      setState(() {
        if (_seen.add(epc)) {
          final first = Map<String, dynamic>.from(m);
          first['count'] = 1;
          _tags.add(first);
        if (_tags.length > 500) {
          // köhnələri at – həm Set, həm List sinxron tut
          final removeCount = _tags.length - 500;
          for (int k = 0; k < removeCount; k++) {
            final removed = _tags.removeAt(0);
            final repc = (removed['epc'] ?? '') as String;
            if (repc.isNotEmpty) _seen.remove(repc);
          }
        }
        } else {
          final i = _tags.indexWhere((e) => e['epc'] == epc);
          if (i >= 0) {
            final curr = Map<String, dynamic>.from(_tags[i]);
            curr['count'] = (curr['count'] ?? 1) + 1;
            if (m['rssi'] != null) curr['rssi'] = m['rssi'];
            if (m['mem'] != null) curr['mem'] = m['mem'];
            _tags[i] = curr;
          }
        }
      });
    }, onError: (e) {
      // optional: log
    });
  }

  @override
  void dispose() {
    if (_invRunning) {
      // səliqəli dayandır, async olsa da gözləməyə ehtiyac yoxdur
      _plugin.stopInventory();
    }
    _tagSub?.cancel();
    _epcCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _readSingle() async {
    if (!_connected) {
      _snack('Əvvəl qoşul: Connect');
      return;
    }
    setState(() => _busy = true);
    try {
      final resp = await _plugin.readSingleTag(
        // wordPtr: _wordPtrSR,
        // len: _lenSR,
        // password: _pwdCtrl.text.trim(),
        // epc: _epcCtrl.text.trim().isEmpty ? null : _epcCtrl.text.trim(),
      );
      final ok = resp['success'] == true;
      setState(() {
        _lastReadResp = resp;
        _lastHex = ok ? (resp['data']?['hex'] as String?) : null;
      });
      _snack(ok ? 'Read OK' : 'Read FAIL: code=${resp['code']}');
    } on PlatformException catch (e) {
      _snack('Read error: ${e.code}');
    } catch (e) {
      _snack('Read error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      final resp = await _plugin.connect();
      final ok = (resp['success'] == true);
      setState(() {
        _connected = ok;
        _baud = (resp['baud'] as num?)?.toInt();
        _lastCode = (resp['code'] as num?)?.toInt();
        _status = ok ? 'Connected' : 'Connect failed';
      });


      _snack(ok ? 'Qoşuldu (baud: $_baud)' : 'Qoşulma alınmadı (code: $_lastCode)');
    } on PlatformException catch (e) {
      setState(() {
        _connected = false;
        _status = 'Connect error: ${e.code}';
      });
      _snack('Xəta: ${e.code}');
    } catch (e) {
      setState(() {
        _connected = false;
        _status = 'Connect error';
      });
      _snack('Connect exception: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _isConnected() async {
    setState(() => _busy = true);
    try {
    final ok = await _plugin.isConnected();
      setState(() {
        _connected = ok;
        _status = ok ? 'Connected' : 'Disconnected';
      });
      _snack(ok ? 'Bağlantı aktivdir' : 'Bağlantı yoxdur');
    } catch (e) {
      _snack('isConnected xətası: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      final ok = await _plugin.disconnect() ?? true;
      setState(() {
        _connected = !ok ? _connected : false;
        _status = 'Disconnected';
      });
      _snack(ok ? 'Bağlantı kəsildi' : 'Kəsmək alınmadı');
    } catch (e) {
      _snack('disconnect xətası: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyPower() async {
    setState(() => _busy = true);
    try {
      final resp = await _plugin.setPower(_power);
      final ok = resp['success'] == true;
      setState(() => _lastSetPowerResp = resp);
      _snack(ok
          ? 'Power yazıldı: ${resp['data']?['power']} dBm (region=${resp['data']?['region']}, S=${resp['data']?['session']}, Q=${resp['data']?['qValue']})'
          : 'Power xətası: code=${resp['code']}');
    } on PlatformException catch (e) {
      _snack('Power yazıla bilmədi: ${e.code}');
    } catch (e) {
      _snack('Power xətası: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // INVENTORY
  Future<void> _startInventory() async {
    if (!_connected) {
      _snack('Əvvəl qoşul: Connect');
      return;
    }
    if (_invRunning) {
      _snack('Inventory artıq işləyir');
      return;
    }
    setState(() { _busy = true; });
    try {
      final resp = await _plugin.startInventory(
        // antenna: 1,      // <-- bunu GÖNDƏRMƏ
        // session: _session,  // S0..S3
        // qValue: _qValue,    // 3-5 arası yaxşıdır, test üçün 4
        // includeTid: _includeTid,
        // tidWordPtr: 2,
        // tidLen: 6,
        //epcFilter: _epcCtrl.text.trim().isEmpty ? null : _epcCtrl.text.trim(),
        // scanTime: 50,       // <-- 10 azdır; 30-50 ver, test üçün 50 qoy
      );
      final ok = resp['success'] == true;
      setState(() {
        _lastInvResp = resp;
        _invRunning = ok;
        if (ok) { _tags.clear(); _seen.clear(); }
      });
      _snack(ok ? 'Inventory başladı' : 'Başlamadı: code=${resp['code']}');
    } on PlatformException catch (e) {
      _snack('Inventory start error: ${e.code}');
    } catch (e) {
      _snack('Inventory start error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopInventory() async {
    if (!_invRunning) {
      _snack('Inventory işləmir');
      return;
    }
    setState(() => _busy = true);
    try {
      final resp = await _plugin.stopInventory();
      final ok = resp['success'] == true;
      setState(() {
        _lastInvResp = resp;
        _invRunning = !ok ? _invRunning : false;
      });
      _snack(ok ? 'Inventory dayandırıldı' : 'Dayandırıla bilmədi: code=${resp['code']}');
    } on PlatformException catch (e) {
      _snack('Inventory stop error: ${e.code}');
    } catch (e) {
      _snack('Inventory stop error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final color = _connected ? Colors.green : Colors.red;
    return Scaffold(
      appBar: AppBar(title: const Text('Chafon H906 – Demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Row(children: [
              Icon(_connected ? Icons.check_circle : Icons.cancel, color: color),
              const SizedBox(width: 8),
              Text('Status: $_status', style: TextStyle(fontSize: 16, color: color)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Text('Baud: ${_baud ?? '-'}   '),
              Text('Last code: ${_lastCode ?? '-'}'),
            ]),
            const SizedBox(height: 24),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),

            // Connect / Check / Disconnect
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _busy ? null : _connect,
                  icon: const Icon(Icons.usb),
                  label: const Text('Connect'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _isConnected,
                  icon: const Icon(Icons.help_outline),
                  label: const Text('Is Connected?'),
                ),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
              ],
            ),
            const Divider(height: 32),

            // Power controls
            Row(
              children: [
                const Text('Power (dBm):  '),
                DropdownButton<int>(
                  value: _power,
                  items: List.generate(34, (i) => i) // 0..33
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: _busy ? null : (v) => setState(() => _power = v ?? _power),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: (_busy || !_connected) ? null : _applyPower,
                  icon: const Icon(Icons.flash_on),
                  label: const Text('Set power'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_lastSetPowerResp != null)
              Text(
                'Son cavab: ${_lastSetPowerResp}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),

            const Divider(height: 32),

            // Single Read
            const Text('Single Read (EPC)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),

            Row(
              children: [
                const Text('WordPtr:  '),
                DropdownButton<int>(
                  value: _wordPtrSR,
                  items: List.generate(33, (i) => i) // 0..32
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: _busy ? null : (v) => setState(() => _wordPtrSR = v ?? _wordPtrSR),
                ),
                const SizedBox(width: 16),
                const Text('Len:  '),
                DropdownButton<int>(
                  value: _lenSR,
                  items: List.generate(32, (i) => i + 1) // 1..32
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: _busy ? null : (v) => setState(() => _lenSR = v ?? _lenSR),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _epcCtrl,
              decoration: const InputDecoration(
                labelText: 'EPC filter (hex, optional)',
                border: OutlineInputBorder(),
                hintText: 'Məs: 300833B2DDD9014000000000',
              ),
             inputFormatters: [
               FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
               UpperCaseTextFormatter(),
             ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pwdCtrl,
              decoration: const InputDecoration(
                labelText: 'Password (8-hex)',
                border: OutlineInputBorder(),
                hintText: '00000000',
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                LengthLimitingTextInputFormatter(8),
                UpperCaseTextFormatter(),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: (_busy || !_connected) ? null : _readSingle,
                  icon: const Icon(Icons.nfc),
                  label: const Text('Read EPC'),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Default: EPC wordPtr=2, len=6',
                    style: TextStyle(color: Colors.black54),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_lastReadResp != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Son oxunuş:', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text('_raw: $_lastReadResp', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    const SizedBox(height: 6),
                    if (_lastHex != null)
                      SelectableText(
                        'HEX: $_lastHex',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                  ],
                ),
              ),

            const Divider(height: 32),

            // Inventory controls
            const Text('Inventory', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Session:'),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _session,
                      items: const [0, 1, 2, 3]
                          .map((v) => DropdownMenuItem(value: v, child: Text('S$v')))
                          .toList(),
                      onChanged: (_busy || !_connected || _invRunning)
                          ? null
                          : (v) => setState(() => _session = v ?? _session),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Q:'),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _qValue,
                      items: List.generate(8, (i) => i + 1)
                          .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                          .toList(),
                      onChanged: (_busy || !_connected || _invRunning)
                          ? null
                          : (v) => setState(() => _qValue = v ?? _qValue),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _includeTid,
                      onChanged: (_busy || !_connected || _invRunning)
                          ? null
                          : (v) => setState(() => _includeTid = v ?? _includeTid),
                    ),
                    const Text('TID də oxu'),
                  ],
                ),
                ElevatedButton.icon(
                  onPressed: (_busy || !_connected || _invRunning) ? null : _startInventory,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Inventory'),
                ),
                ElevatedButton.icon(
                  onPressed: (_busy || !_connected || !_invRunning) ? null : _stopInventory,
                  icon: const Icon(Icons.stop),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                  label: const Text('Stop Inventory'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_lastInvResp != null) ...[
              const Text(
                'Inventory cavabı:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200), // çox uzundursa scroll
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black12),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(_lastInvResp),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text('Unikal tag: ${_tags.length}   Ümumi hitlər: ${_tags.fold<int>(0, (p, e) => p + (e['count'] as int? ?? 1))}',
         style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),

            // Inventory results list
            if (_tags.isEmpty)
              const Text('Hələ tag yoxdur...', style: TextStyle(color: Colors.black54))
            else
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _tags.length,
                  itemBuilder: (_, i) {
                    final t = _tags[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.label),
                      title: SelectableText(
                        (t['epc'] ?? '') as String,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: Text([
                        if ((t['mem'] ?? '').toString().isNotEmpty) 'MEM: ${t['mem']}',
                        if (t['rssi'] != null) 'RSSI: ${t['rssi']}',
                        if (t['count'] != null) 'Count: ${t['count']}',
                      ].join('   ')),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}