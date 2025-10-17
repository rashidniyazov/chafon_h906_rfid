import 'dart:async';
import 'package:flutter/services.dart';

class ChafonH906Rfid {
  static const MethodChannel _ch  = MethodChannel('chafon_h906_rfid');
  static const EventChannel  _evt = EventChannel('chafon_h906_rfid/tags');

  /// Native-dən gələn tag-lar: {epc, rssi, optional: mem, tid} və ya {stopped:true}
  Stream<Map<String, dynamic>> get onTag =>
      _evt.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e));

  Future<Map<String, dynamic>> connect() async =>
      Map<String, dynamic>.from(await _ch.invokeMethod('connect'));

  Future<bool> isConnected() async =>
      await _ch.invokeMethod('isConnected') == true;

  Future<bool> disconnect() async =>
      await _ch.invokeMethod('disconnect') == true;

  Future<Map<String, dynamic>> setPower(int power) async =>
      Map<String, dynamic>.from(await _ch.invokeMethod('setPower', {'power': power}));

  Future<Map<String, dynamic>> readSingleTag({
    int wordPtr = 2,
    int len = 6,
    String password = '00000000',
    String? epc,
  }) async {
    final args = {
      'wordPtr': wordPtr,
      'len': len,
      'password': password,
      if (epc != null && epc.isNotEmpty) 'epc': epc,
    };
    return Map<String, dynamic>.from(await _ch.invokeMethod('readSingleTag', args));
  }

  Future<Map<String, dynamic>> startInventory({
    int? scanTime,
    int? qValue,
    int? session,
    int? antenna,
    bool includeTid = false,
    int tidWordPtr = 2,
    int tidLen = 6,
    String? epcFilter,
    List<String>? masksHex,
  }) async =>
      Map<String, dynamic>.from(await _ch.invokeMethod('startInventory', {
        'scanTime': 50,
        'qValue': 4,
        'session': 0,
        'antenna': antenna,
        'includeTid': includeTid,
        'tidWordPtr': tidWordPtr,
        'tidLen': tidLen,
        'epcFilter': epcFilter,
        'masksHex': masksHex,
      }));

  Future<Map<String, dynamic>> stopInventory() async =>
      Map<String, dynamic>.from(await _ch.invokeMethod('stopInventory'));
}
