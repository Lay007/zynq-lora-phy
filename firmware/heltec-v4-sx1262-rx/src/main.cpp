// Heltec WiFi LoRa 32 V4 SX1262 receiver for packet-error-rate measurements.
//
// Every packet the SX1262 hands over is reported on one serial line, CRC
// failures included, so the host can count what was sent against what was
// received:
//
//   RX n=<count> state=<0|crc|other> len=<bytes> rssi=<dBm> snr=<dB>
//      ferr=<Hz> payload=<hex>
//
// state=0 is a valid packet (header and payload CRC), state=crc a payload CRC
// mismatch (RadioLib -7). The front end is left in its receive path (KCT8103L
// CTX low, the SX1262 DIO2 switch low); `set boost on|off` selects the SX1262
// boosted or power-saving receive gain explicitly, so a curve always names it.

#include <Arduino.h>
#include <RadioLib.h>
#include <SPI.h>

#include <cstdint>
#include <cstdlib>

#include "board_config.hpp"

namespace {

constexpr char kFirmwareVersion[] = "0.1.0";
constexpr size_t kMaxPacket = 255;
constexpr uint32_t kRadioPowerUpDelayMs = 1500;

struct Profile {
  float frequencyMhz = 868.1F;
  float bandwidthKhz = 125.0F;
  uint8_t spreadingFactor = 7;
  uint8_t codingRate = 5;
  uint8_t syncWord = 0x12;
  uint16_t preambleSymbols = 12;
  bool crcEnabled = true;
  bool boostedGain = true;
};

SX1262 radio(new Module(board::kRadioCs, board::kRadioDio1, board::kRadioReset,
                        board::kRadioBusy));
Profile profile;
volatile bool packetFlag = false;
bool receiving = false;
uint32_t packetCount = 0;
String serialLine;
board::RevisionProbe revisionProbe{board::Revision::Unknown, 0, 0};

#if defined(ESP8266) || defined(ESP32)
ICACHE_RAM_ATTR
#endif
void onPacket() { packetFlag = true; }

bool ok(int16_t state, const char* what) {
  if (state == RADIOLIB_ERR_NONE) return true;
  Serial.printf("ERR operation=%s state=%d\n", what, state);
  return false;
}

bool apply(const Profile& p) {
  radio.standby();
  return ok(radio.setFrequency(p.frequencyMhz), "setFrequency") &&
         ok(radio.setBandwidth(p.bandwidthKhz), "setBandwidth") &&
         ok(radio.setSpreadingFactor(p.spreadingFactor), "setSpreadingFactor") &&
         ok(radio.setCodingRate(p.codingRate), "setCodingRate") &&
         ok(radio.setSyncWord(p.syncWord), "setSyncWord") &&
         ok(radio.setPreambleLength(p.preambleSymbols), "setPreambleLength") &&
         ok(radio.setCRC(p.crcEnabled ? 2 : 0), "setCRC") &&
         ok(radio.setRxBoostedGainMode(p.boostedGain), "setRxBoostedGainMode");
}

void printProfile() {
  Serial.printf(
      "PROFILE freq_mhz=%.3f bw_khz=%.1f sf=%u cr=4/%u sync=0x%02X preamble=%u "
      "crc=%s boost=%s receiving=%s board_revision=%s fem=%s firmware=%s\n",
      profile.frequencyMhz, profile.bandwidthKhz, profile.spreadingFactor,
      profile.codingRate, profile.syncWord, profile.preambleSymbols,
      profile.crcEnabled ? "on" : "off", profile.boostedGain ? "on" : "off",
      receiving ? "yes" : "no", board::revisionName(revisionProbe.revision),
      board::femModeName(revisionProbe.revision), kFirmwareVersion);
}

void startReceiving() {
  packetFlag = false;
  receiving = ok(radio.startReceive(), "startReceive");
}

void printHelp() {
  Serial.println("commands: help | show | version | rx start | rx stop | reset count");
  Serial.println("  set freq <MHz> | set bw <kHz> | set sf <5..12> | set cr <5..8>");
  Serial.println("  set sync <byte> | set preamble <n> | set crc <on|off> | set boost <on|off>");
}

void handle(String line) {
  line.trim();
  if (line.isEmpty()) return;
  String cmd = line;
  cmd.toLowerCase();
  if (cmd == "help") { printHelp(); return; }
  if (cmd == "show") { printProfile(); return; }
  if (cmd == "version") { Serial.printf("zynq-lora-heltec-v4-sx1262-rx %s\n", kFirmwareVersion); return; }
  if (cmd == "rx start") { startReceiving(); Serial.println(receiving ? "OK receiving" : "ERR not receiving"); return; }
  if (cmd == "rx stop") { radio.standby(); receiving = false; Serial.println("OK stopped"); return; }
  if (cmd == "reset count") { packetCount = 0; Serial.println("OK count=0"); return; }
  if (cmd.startsWith("set ")) {
    const int space = cmd.indexOf(' ', 4);
    if (space < 0) { Serial.println("ERR usage: set <name> <value>"); return; }
    const String name = cmd.substring(4, space);
    const String value = cmd.substring(space + 1);
    Profile next = profile;
    if (name == "freq") next.frequencyMhz = value.toFloat();
    else if (name == "bw") next.bandwidthKhz = value.toFloat();
    else if (name == "sf") next.spreadingFactor = static_cast<uint8_t>(value.toInt());
    else if (name == "cr") next.codingRate = static_cast<uint8_t>(value.toInt());
    else if (name == "sync") next.syncWord = static_cast<uint8_t>(strtol(value.c_str(), nullptr, 0));
    else if (name == "preamble") next.preambleSymbols = static_cast<uint16_t>(value.toInt());
    else if (name == "crc") next.crcEnabled = value == "on";
    else if (name == "boost") next.boostedGain = value == "on";
    else { Serial.println("ERR unknown setting"); return; }
    const bool wasReceiving = receiving;
    receiving = false;
    if (apply(next)) {
      profile = next;
      Serial.println("OK");
    } else {
      apply(profile);
    }
    if (wasReceiving) startReceiving();
    printProfile();
    return;
  }
  Serial.println("ERR unknown command; type help");
}

void serviceSerial() {
  while (Serial.available() > 0) {
    const char c = static_cast<char>(Serial.read());
    if (c == '\n' || c == '\r') {
      if (!serialLine.isEmpty()) handle(serialLine);
      serialLine = "";
    } else if (serialLine.length() < 128) {
      serialLine += c;
    }
  }
}

void servicePacket() {
  if (!packetFlag) return;
  packetFlag = false;
  uint8_t data[kMaxPacket];
  const size_t length = radio.getPacketLength();
  const int16_t state = radio.readData(data, length);
  ++packetCount;
  const char* stateName = state == RADIOLIB_ERR_NONE ? "0"
                          : state == RADIOLIB_ERR_CRC_MISMATCH ? "crc" : "other";
  Serial.printf("RX n=%lu state=%s code=%d len=%u rssi=%.1f snr=%.2f ferr=%.1f payload=",
                static_cast<unsigned long>(packetCount), stateName, state,
                static_cast<unsigned>(length), radio.getRSSI(), radio.getSNR(),
                radio.getFrequencyError());
  for (size_t i = 0; i < length && i < kMaxPacket; ++i) Serial.printf("%02x", data[i]);
  Serial.println();
  board::setLed(true);
  delay(5);
  board::setLed(false);
  startReceiving();
}

}  // namespace

void setup() {
  revisionProbe = board::detectRevision();
  board::preparePowerAndRfFrontend();
  board::setTransmitBypass(revisionProbe.revision, false);
  pinMode(board::kLed, OUTPUT);
  board::setLed(false);

  Serial.begin(115200);
  const uint32_t start = millis();
  while (!Serial && millis() - start < 3000) delay(10);

  SPI.begin(board::kRadioSclk, board::kRadioMiso, board::kRadioMosi);
  delay(kRadioPowerUpDelayMs);

  Serial.printf("Initializing Heltec V4 SX1262 receiver firmware %s\n", kFirmwareVersion);
  const int16_t begin = radio.begin(profile.frequencyMhz, profile.bandwidthKhz,
                                    profile.spreadingFactor, profile.codingRate,
                                    profile.syncWord, 0, profile.preambleSymbols, 1.8F);
  if (!ok(begin, "begin") || !apply(profile)) {
    Serial.println("FATAL radio initialization failed");
    while (true) { board::setLed(true); delay(100); board::setLed(false); delay(900); }
  }
  radio.setDio2AsRfSwitch(true);
  radio.setPacketReceivedAction(onPacket);
  Serial.println("READY receiver stopped; type 'rx start'");
  printProfile();
}

void loop() {
  serviceSerial();
  if (receiving) servicePacket();
  delay(1);
}
