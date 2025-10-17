import 'package:flutter_test/flutter_test.dart';
import 'package:chafon_h906_rfid/chafon_h906_rfid.dart';
import 'package:chafon_h906_rfid/chafon_h906_rfid_platform_interface.dart';
import 'package:chafon_h906_rfid/chafon_h906_rfid_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockChafonH906RfidPlatform
    with MockPlatformInterfaceMixin
    implements ChafonH906RfidPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final ChafonH906RfidPlatform initialPlatform = ChafonH906RfidPlatform.instance;

  test('$MethodChannelChafonH906Rfid is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelChafonH906Rfid>());
  });

  test('getPlatformVersion', () async {
    ChafonH906Rfid chafonH906RfidPlugin = ChafonH906Rfid();
    MockChafonH906RfidPlatform fakePlatform = MockChafonH906RfidPlatform();
    ChafonH906RfidPlatform.instance = fakePlatform;

    //expect(await chafonH906RfidPlugin.getPlatformVersion(), '42');
  });
}
