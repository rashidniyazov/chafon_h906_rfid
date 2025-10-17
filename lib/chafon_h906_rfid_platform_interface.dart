import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'chafon_h906_rfid_method_channel.dart';

abstract class ChafonH906RfidPlatform extends PlatformInterface {
  /// Constructs a ChafonH906RfidPlatform.
  ChafonH906RfidPlatform() : super(token: _token);

  static final Object _token = Object();

  static ChafonH906RfidPlatform _instance = MethodChannelChafonH906Rfid();

  /// The default instance of [ChafonH906RfidPlatform] to use.
  ///
  /// Defaults to [MethodChannelChafonH906Rfid].
  static ChafonH906RfidPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ChafonH906RfidPlatform] when
  /// they register themselves.
  static set instance(ChafonH906RfidPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
