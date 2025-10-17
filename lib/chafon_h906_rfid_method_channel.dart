import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'chafon_h906_rfid_platform_interface.dart';

/// An implementation of [ChafonH906RfidPlatform] that uses method channels.
class MethodChannelChafonH906Rfid extends ChafonH906RfidPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('chafon_h906_rfid');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
