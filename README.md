cat > README.md <<'EOF'
# chafon_h906_rfid

Flutter plugin for **Chafon H906** UHF RFID reader (Android).  
Works on device’s own Android (UART like `/dev/ttyHSL0`) or via OTG host.

## ✨ Features
- Connect / Disconnect
- Set output power (0–33 dBm)
- Start/Stop **Inventory** (EPC)
- **Read single tag**
- Region config (EU/FCC)

## 📦 Install
```yaml
dependencies:
  chafon_h906_rfid: ^0.1.0
