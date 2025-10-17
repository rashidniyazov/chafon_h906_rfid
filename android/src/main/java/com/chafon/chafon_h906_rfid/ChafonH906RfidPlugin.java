package com.chafon.chafon_h906_rfid;

import androidx.annotation.NonNull;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import com.rfid.trans.BaseReader;
import com.rfid.trans.OtgUtils;
import com.rfid.trans.ReadTag;
import com.rfid.trans.TagCallback;

import java.util.Arrays;
import java.util.HashMap;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** ChafonH906RfidPlugin — Inventory_G2 loop */
public class ChafonH906RfidPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {

  private MethodChannel channel;
  private EventChannel eventChannel;
  private EventChannel.EventSink tagSink;

  private Context context;
  private boolean connected = false;
  private int currentBaud = 115200;

  private final BaseReader reader = new BaseReader();
  private static final String DEV_PORT = "/dev/ttyHSL0";
  private static final int BAUD_PRIMARY = 115200;
  private static final int BAUD_FALLBACK = 57600;

  private static final byte COM_ADDR = (byte) 0xFF;

  // ===== Region seçimi =====
  // EU band — 865 ~ 868 MHz
  private static final int REGION_BAND = 4; // EU:4, FCC:2
  private static final int REGION_MIN  = 0;
  private static final int REGION_MAX  = 14; // EU üçün 0..14; FCC üçün 0..62 istifadə etməlisən

  // Inventory idarəetməsi
  private final AtomicBoolean ivtRunning = new AtomicBoolean(false);
  private ExecutorService ivtExec;

  // Loop parametrləri (default)
  private byte defaultQ       = 4;
  private byte defaultSession = 0;
  private byte defaultTarget  = 0;
  private byte defaultAntenna = (byte)0x80; // -128 == 0x80 auto
  private byte defaultScanTime= 10;         // SDK demo-da 10 idi

  // Main thread handler — EventChannel üçün
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  // TID oxu üçün flag-lar (callback içində istifadə ediləcək)
  private volatile boolean includeTidFlag = false;
  private volatile byte tidWordPtrB = 0;
  private volatile byte tidLenB     = 6;
  private volatile String activeEpcFilter = null; // Inventory_G2 maskası kimi

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();

    channel = new MethodChannel(binding.getBinaryMessenger(), "chafon_h906_rfid");
    channel.setMethodCallHandler(this);

    eventChannel = new EventChannel(binding.getBinaryMessenger(), "chafon_h906_rfid/tags");
    eventChannel.setStreamHandler(new EventChannel.StreamHandler() {
      @Override public void onListen(Object args, EventChannel.EventSink sink) { tagSink = sink; }
      @Override public void onCancel(Object args) { tagSink = null; }
    });

    // SDK callback: hər tag gələndə EventChannel-a ötür
    try {
      reader.SetCallBack(new TagCallback() {
        @Override public void tagCallback(ReadTag t) {
          if (tagSink == null) return;

          Map<String, Object> m = new HashMap<>();
          final String epc = t.epcId != null ? t.epcId.toUpperCase() : "";
          m.put("epc", epc);
          if (t.memId != null && !t.memId.isEmpty()) m.put("mem", t.memId.toUpperCase());
          m.put("rssi", t.rssi);

          // TID istənibsə, həmən tag üçün əlavə oxu et (Mem=2)
          if (includeTidFlag && epc.length() >= 4) {
            try {
              String tidHex = readTidForEpc(epc, tidWordPtrB, tidLenB);
              if (tidHex != null && !tidHex.isEmpty()) {
                m.put("tid", tidHex);
              }
            } catch (Throwable ignore) {}
          }

          emitOnMain(m);
        }

        @Override public void StopReadCallBack() {
          ivtRunning.set(false);
          Map<String, Object> stopped = new HashMap<>();
          stopped.put("stopped", true);
          emitOnMain(stopped);
        }
      });
    } catch (Throwable ignore) {}
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "getPlatformVersion":
        result.success("Android " + android.os.Build.VERSION.RELEASE);
        break;

      case "connect":
        Executors.newSingleThreadExecutor().execute(() -> {
          int rc = connectAuto();
          Map<String, Object> resp = new HashMap<>();
          resp.put("success", rc == 0);
          resp.put("code", rc);
          resp.put("baud", currentBaud);
          mainHandler.post(() -> result.success(resp));
        });
        break;

      case "isConnected":
        Executors.newSingleThreadExecutor().execute(() -> {
          boolean ok = connected && isActuallyConnected();
          if (!ok) {
            connected = false;
            try { OtgUtils.set53GPIOEnabled(true); } catch (Throwable ignore) {}
            int rc = connectAuto(); // auto-reconnect
            ok = (rc == 0);
          }
          boolean finalOk = ok;
          mainHandler.post(() -> result.success(finalOk));
        });
        break;

      case "disconnect":
        Executors.newSingleThreadExecutor().execute(() -> {
          stopInventoryLoop(); // ehtiyat
          disconnectReader();
          mainHandler.post(() -> result.success(true));
        });
        break;

      case "setPower": {
        Integer powerArg = call.argument("power");
        if (powerArg == null) {
          result.error("ARG", "power is required", null);
          return;
        }
        final int power = Math.max(0, Math.min(33, powerArg)); // 0..33 clamp
        Executors.newSingleThreadExecutor().execute(() -> {
          Map<String, Object> resp = setPowerOnly(power);
          mainHandler.post(() -> {
            if ((boolean) resp.get("success")) result.success(resp);
            else result.error(String.valueOf(resp.get("code")), (String) resp.get("message"), resp);
          });
        });
        break;
      }

      case "readSingleTag": {
        Executors.newSingleThreadExecutor().execute(() -> {
          int wordPtr = safeInt(call.argument("wordPtr"), 2);
          int len     = safeInt(call.argument("len"), 6);
          String pwd  = safeStr(call.argument("password"), "00000000");
          String epc  = safeStr(call.argument("epc"), "");

          Map<String, Object> resp = readSingleEpc(wordPtr, len, pwd, epc);
          mainHandler.post(() -> {
            if ((boolean) resp.get("success")) result.success(resp);
            else result.error(String.valueOf(resp.get("code")), (String) resp.get("message"), resp);
          });
        });
        break;
      }

      // INVENTORY_G2 loop
      case "startInventory": {
        Executors.newSingleThreadExecutor().execute(() -> {
          Map<String, Object> resp = startInventoryLoopG2(call);
          mainHandler.post(() -> {
            if ((boolean) resp.get("success")) result.success(resp);
            else result.error(String.valueOf(resp.get("code")), (String) resp.get("message"), resp);
          });
        });
        break;
      }
      case "stopInventory": {
        Executors.newSingleThreadExecutor().execute(() -> {
          Map<String, Object> resp = stopInventoryLoop();
          mainHandler.post(() -> result.success(resp));
        });
        break;
      }

      default:
        result.notImplemented();
        break;
    }
  }

  // ---------------- Connection helpers ----------------

  private int connectAuto() {
    try { OtgUtils.set53GPIOEnabled(true); } catch (Throwable ignore) {}

    int rc = reader.Connect(DEV_PORT, BAUD_PRIMARY, 1);
    if (rc != 0) {
      rc = reader.Connect(DEV_PORT, BAUD_FALLBACK, 1);
      if (rc == 0) currentBaud = BAUD_FALLBACK;
    } else {
      currentBaud = BAUD_PRIMARY;
    }

    if (rc == 0) {
      connected = true;
      //setRegion();
      initDefaultSession();   // Q=4, Session=0
    } else {
      try { OtgUtils.set53GPIOEnabled(true); } catch (Throwable ignore) {}
    }
    return rc;
  }

  private boolean isActuallyConnected() {
    try {
      byte[] param = new byte[6];
      int rc = reader.GetReadParameter(COM_ADDR, param);
      return rc == 0;
    } catch (Throwable t) {
      return false;
    }
  }

  private void disconnectReader() {
    try { reader.DisConnect(); } catch (Throwable ignore) {}
    connected = false;
    try { OtgUtils.set53GPIOEnabled(true); } catch (Throwable ignore) {}
  }

  private void initDefaultSession() {
    try {
      byte[] param = new byte[6];
      int res = reader.GetReadParameter(COM_ADDR, param);
      if (res == 0) {
        param[0] = defaultQ;
        param[1] = defaultSession;
        byte[] newParam = Arrays.copyOf(param, 5);
        reader.SetReadParameter(COM_ADDR, newParam);
        Log.i("H906", "Default Q=" + defaultQ + ", Session=" + defaultSession + " yazıldı.");
      } else {
        Log.e("H906", "GetReadParameter alınmadı, kod=" + res);
      }
    } catch (Exception e) {
      Log.e("H906", "initDefaultSession xətası: " + e.getMessage());
    }
  }

  // ---------------- POWER / REGION ----------------

  private Map<String, Object> setPowerOnly(int power) {
    HashMap<String, Object> resp = new HashMap<>();
    try {
      if (!(connected && isActuallyConnected())) {
        int rc = connectAuto();
        if (rc != 0) {
          resp.put("success", false);
          resp.put("code", rc);
          resp.put("message", "connect failed");
          return resp;
        }
      }

//      int rcRegion = setRegion();
//      if (rcRegion != 0) {
//        resp.put("success", false);
//        resp.put("code", rcRegion);
//        resp.put("message", "SetRegion failed");
//        return resp;
//      }

      byte[] ivt = new byte[6];
      int rcGet = reader.GetReadParameter(COM_ADDR, ivt);
      if (rcGet == 0) {
        ivt[0] = defaultQ;
        ivt[1] = defaultSession;
        byte[] toSet = Arrays.copyOf(ivt, 5);
        reader.SetReadParameter(COM_ADDR, toSet);
      }

      int clamped = Math.max(0, Math.min(33, power));
      int rcPower = reader.SetRfPower(COM_ADDR, (byte) clamped);
      if (rcPower != 0) {
        resp.put("success", false);
        resp.put("code", rcPower);
        resp.put("message", "SetRfPower failed");
        return resp;
      }

      HashMap<String, Object> data = new HashMap<>();
      data.put("power", clamped);
      data.put("region", (REGION_BAND == 4) ? "EU" : "FCC/Other");
      data.put("session", (int)defaultSession);
      data.put("qValue",  (int)defaultQ);
      resp.put("success", true);
      resp.put("code", 0);
      resp.put("data", data);
      return resp;

    } catch (Exception e) {
      resp.put("success", false);
      resp.put("code", -1);
      resp.put("message", "exception: " + e.getMessage());
      return resp;
    }
  }

  /** Region yaz — lazım olsa FCC üçün band=2, min=0, max=62 ver. */
  private int setRegion() {
    int rc = reader.SetRegion(COM_ADDR, REGION_BAND, REGION_MAX, REGION_MIN);
    if (rc == 0) return 0;

    rc = reader.SetRegion(COM_ADDR, REGION_BAND, REGION_MIN, REGION_MAX);
    if (rc == 0) return 0;

    try {
      rc = reader.SetRegion(COM_ADDR, 0, REGION_BAND, REGION_MAX, REGION_MIN);
      if (rc == 0) return 0;
      rc = reader.SetRegion(COM_ADDR, 0, REGION_BAND, REGION_MIN, REGION_MAX);
    } catch (Throwable ignore) {}

    return rc;
  }

  // ---------------- SINGLE READ (EPC) ----------------

  private Map<String, Object> readSingleEpc(int wordPtr, int len, String password, String epcFilter) {
    HashMap<String, Object> resp = new HashMap<>();
    try {
      if (!(connected && isActuallyConnected())) {
        int rcConn = connectAuto();
        if (rcConn != 0) {
          resp.put("success", false);
          resp.put("code", rcConn);
          resp.put("message", "connect failed");
          return resp;
        }
      }
      final byte MEM_EPC = 1;

      byte wordPtrB = (byte) Math.max(0, Math.min(255, wordPtr));
      byte numB     = (byte) Math.max(1, Math.min(64,  len));

      byte[] passBytes = hexToPassword4(password);

      byte[] epcBytes = new byte[0];
      byte eNum = 0;
      if (epcFilter != null && !epcFilter.isEmpty()) {
        epcBytes = hexToBytes(epcFilter);
        eNum = (byte) Math.min(15, (epcBytes.length));
        if (epcBytes.length != (eNum & 0xFF) * 2) {
          eNum = (byte) Math.min(15, epcBytes.length / 2);
          epcBytes = Arrays.copyOf(epcBytes, (eNum & 0xFF) * 2);
        }
      }

      byte maskMem = 0;
      byte[] maskAdr = new byte[]{0x00, 0x00};
      byte maskLen = 0x00;
      byte[] maskData = new byte[0];

      byte[] dataBuf = new byte[(numB & 0xFF) * 2];
      byte[] err = new byte[1];

      int rc = reader.ReadData_G2(
              COM_ADDR,
              eNum,
              epcBytes,
              MEM_EPC,
              wordPtrB,
              numB,
              passBytes,
              maskMem,
              maskAdr,
              maskLen,
              maskData,
              dataBuf,
              err
      );

      if (rc != 0) {
        resp.put("success", false);
        resp.put("code", rc);
        resp.put("message", "ReadData_G2 failed, err=" + (err[0] & 0xFF));
        return resp;
      }

      String hex = bytesToHex(dataBuf, 0, dataBuf.length);
      HashMap<String, Object> dataMap = new HashMap<>();
      dataMap.put("hex", hex);
      dataMap.put("mem", 1);
      dataMap.put("wordPtr", (int)(wordPtrB & 0xFF));
      dataMap.put("len", (int)(numB & 0xFF));
      dataMap.put("epcFilter", epcFilter);

      resp.put("success", true);
      resp.put("code", 0);
      resp.put("data", dataMap);
      return resp;

    } catch (Throwable t) {
      resp.put("success", false);
      resp.put("code", -1);
      resp.put("message", "exception: " + t.getMessage());
      return resp;
    }
  }

  // ---------------- INVENTORY (Inventory_G2 loop) ----------------

  /**
   * Flutter: startInventory({
   *   int? scanTime, int? qValue, int? session,
   *   int? antenna, bool includeTid=false, int tidWordPtr=0, int tidLen=6,
   *   String? epcFilter, List<String>? masksHex
   * })
   */
  private Map<String, Object> startInventoryLoopG2(MethodCall call) {
    HashMap<String, Object> resp = new HashMap<>();
    try {
      if (ivtRunning.get()) {
        resp.put("success", true);
        resp.put("code", 0);
        resp.put("message", "already running");
        return resp;
      }
      if (!(connected && isActuallyConnected())) {
        int rc = connectAuto();
        if (rc != 0) {
          resp.put("success", false);
          resp.put("code", rc);
          resp.put("message", "connect failed");
          return resp;
        }
      }

      Integer scanTimeArg     = call.argument("scanTime");
      Integer qValueArg       = call.argument("qValue");
      Integer sessionArg      = call.argument("session");
      Integer antennaArg      = call.argument("antenna");
      final String epcFilter  = call.argument("epcFilter");
      final List<String> masks= call.argument("masksHex");
      final Boolean includeTidArg = call.argument("includeTid");
      final Integer tidWordPtrArg = call.argument("tidWordPtr");
      final Integer tidLenArg     = call.argument("tidLen");

      // Q/Session hazırla
      byte[] cur = new byte[6];
      int rcGet = reader.GetReadParameter(COM_ADDR, cur);
      byte qVal = (rcGet == 0) ? cur[0] : defaultQ;
      byte ses  = (rcGet == 0) ? cur[1] : defaultSession;

      if (qValueArg != null)  qVal = (byte) Math.max(0, Math.min(15, qValueArg));
      if (sessionArg != null) ses  = (byte) Math.max(0, Math.min(3,  sessionArg));

      byte[] toSet = Arrays.copyOf(cur, 5);
      toSet[0] = qVal;
      toSet[1] = ses;
      reader.SetReadParameter(COM_ADDR, toSet);

      final byte scanTime = (byte) (scanTimeArg != null ? Math.max(0, Math.min(255, scanTimeArg)) : defaultScanTime);
      final byte ant      = (antennaArg != null) ? (byte)Math.max(0, Math.min(127, antennaArg)) : defaultAntenna;

      // EPC maskası (Inventory_G2 üçün: MaskMem=1, MaskAdr=0x00 0x20, MaskLen=bit)
      byte[] maskData = new byte[0];
      byte   maskLenBits = 0;
      if (epcFilter != null && !epcFilter.isEmpty()) {
        maskData = hexToBytes(epcFilter);
        maskLenBits = (byte)(maskData.length * 8);
        activeEpcFilter = epcFilter;
      } else if (masks != null && !masks.isEmpty()) {
        byte[] epcBytes = hexToBytes(masks.get(0));
        maskData = epcBytes;
        maskLenBits = (byte)(epcBytes.length * 8);
        activeEpcFilter = masks.get(0);
      } else {
        activeEpcFilter = null;
      }

      // TID flag-lar
      includeTidFlag = (includeTidArg != null) ? includeTidArg : false;
      tidWordPtrB = (byte)((tidWordPtrArg != null) ? Math.max(0, Math.min(255, tidWordPtrArg)) : 0);
      tidLenB     = (byte)((tidLenArg     != null) ? Math.max(1, Math.min(64,  tidLenArg))     : 6);

      // Loop: Inventory_G2 — SDK callback vasitəsi ilə tag-lar gələcək
      ivtRunning.set(true);
      ivtExec = Executors.newSingleThreadExecutor();
      final byte fQ = qVal;
      final byte fS = ses;
      final byte[] fMaskData = maskData;       // effectively final
      final byte   fMaskLen  = maskLenBits;

      ivtExec.execute(() -> {
        try {
          while (ivtRunning.get()) {
            int[] cardNum = new int[1];
            // Inventory_G2(comAddr, Q, Session, WordPtr=0, Num=0, Target, Ant, ScanTime, MaskMem, MaskAdr[2], MaskLen, MaskData, List?=null, CardNum, Beep=false)
            int rc = reader.Inventory_G2(
                    COM_ADDR,
                    fQ,
                    fS,
                    (byte)0,
                    (byte)0,
                    defaultTarget,
                    ant,
                    scanTime,
                    (byte)1,                  // MaskMem = EPC
                    new byte[]{0x00, 0x20},   // MaskAdr (PC-dən sonra)
                    fMaskLen,
                    fMaskData,
                    null,                      // list — null veririk; callback işləyir
                    cardNum,
                    false
            );
            // Debug üçün:
            Log.d("H906", "Inventory_G2 rc=" + rc + " cardNum=" + cardNum[0]);

            try { Thread.sleep(20); } catch (InterruptedException ignored) {}
          }
        } catch (Throwable loopErr) {
          Log.e("H906", "inventory loop error: " + loopErr.getMessage());
          ivtRunning.set(false);
          Map<String, Object> stopped = new HashMap<>();
          stopped.put("stopped", true);
          emitOnMain(stopped);
        }
      });

      resp.put("success", true);
      resp.put("code", 0);
      resp.put("message", "started");
      return resp;

    } catch (Throwable t) {
      resp.put("success", false);
      resp.put("code", -1);
      resp.put("message", "exception: " + t.getMessage());
      return resp;
    }
  }

  private Map<String, Object> stopInventoryLoop() {
    HashMap<String, Object> resp = new HashMap<>();
    try {
      if (!ivtRunning.get()) {
        resp.put("success", false);
        resp.put("code", 0);
        resp.put("message", "not running");
        return resp;
      }
      ivtRunning.set(false);
      if (ivtExec != null) {
        ivtExec.shutdownNow();
        ivtExec = null;
      }
      resp.put("success", true);
      resp.put("code", 0);
      resp.put("message", "stopped");
      return resp;

    } catch (Throwable t) {
      resp.put("success", false);
      resp.put("code", -1);
      resp.put("message", "exception: " + t.getMessage());
      return resp;
    }
  }

  // --------- TID oxu helper (EPC-ə maska ilə) ---------
  private String readTidForEpc(String epcHex, byte wordPtr, byte len) {
    try {
      // EPC maskasını ENum kimi də verə bilərik, amma bu SDK imzasında
      // mask sahələrindən istifadə edəcəyik
      final byte MEM_TID = 2;

      byte[] dataBuf = new byte[(len & 0xFF) * 2];
      byte[] err = new byte[1];

      // EPC maskası
      byte[] maskData = hexToBytes(epcHex);
      byte maskLenBits = (byte)(maskData.length * 8);

      int rc = reader.ReadData_G2(
              COM_ADDR,
              (byte)0,               // ENum=0
              new byte[0],           // EPC[] boş
              MEM_TID,
              wordPtr,
              len,
              hexToPassword4("00000000"), // lazım olarsa param edərsən
              (byte)1,               // MaskMem = EPC
              new byte[]{0x00, 0x20},// MaskAdr
              maskLenBits,
              maskData,
              dataBuf,
              err
      );
      if (rc == 0) {
        return bytesToHex(dataBuf, 0, dataBuf.length);
      }
    } catch (Throwable ignore) {}
    return null;
  }

  // ---------------- utils ----------------

  private void emitOnMain(final Map<String, Object> event) {
    if (tagSink == null) return;
    mainHandler.post(() -> {
      if (tagSink != null) tagSink.success(event);
    });
  }

  private static int safeInt(Integer v, int def) { return v == null ? def : v; }
  private static String safeStr(String v, String def) { return v == null ? def : v; }

  private byte[] hexToBytes(String s) {
    if (s == null) return new byte[0];
    s = s.replaceAll("\\s+", "");
    if (s.length() % 2 != 0) s = "0" + s;
    byte[] out = new byte[s.length() / 2];
    for (int i = 0; i < s.length(); i += 2) {
      out[i / 2] = (byte) ((Character.digit(s.charAt(i), 16) << 4)
              + Character.digit(s.charAt(i + 1), 16));
    }
    return out;
  }

  private byte[] hexToPassword4(String pwd) {
    String p = (pwd == null || pwd.isEmpty()) ? "00000000" : pwd.replaceAll("\\s+","");
    if (p.length() != 8) p = "00000000";
    byte[] full = hexToBytes(p);
    if (full.length < 4) {
      byte[] fix = new byte[4];
      System.arraycopy(full, 0, fix, 4 - full.length, full.length);
      return fix;
    } else if (full.length > 4) {
      return Arrays.copyOfRange(full, 0, 4);
    }
    return full;
  }

  private String bytesToHex(byte[] bytes, int offset, int length) {
    StringBuilder sb = new StringBuilder();
    for (int i = offset; i < offset + length && i < bytes.length; i++) {
      sb.append(String.format("%02X", bytes[i]));
    }
    return sb.toString();
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    stopInventoryLoop();
    channel.setMethodCallHandler(null);
  }
}
