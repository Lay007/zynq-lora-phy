// LILYGO T3-S3 V1.2 LR1121 receiver for packet-error-rate measurements.
//
// Every packet the LR1121 hands over is reported on one serial line, CRC
// failures included, so the host can count what was sent against what was
// received:
//
//   RX n=<count> state=<0|crc|other> len=<bytes> rssi=<dBm> snr=<dB>
//      ferr=<Hz> payload=<hex>
//
// state=0 is a valid packet (header and payload CRC), state=crc a payload CRC
// mismatch (RadioLib -7). The RF switch (DIO5/DIO6) is driven by the LR1121
// from the same table as the transmitter firmware (RX: DIO5 high); `set boost
// on|off` selects the boosted receive gain explicitly, so a curve names it.
// RadioLib reports no frequency error for the LR1121: ferr prints 0.

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

class LilygoLR1121 : public LR1121 {
 public:
  explicit LilygoLR1121(Module* module) : LR1121(module) { chipType = board::kRadioDeviceId; }
};

LilygoLR1121 radio(new Module(board::kRadioCs, board::kRadioDio9, board::kRadioReset,
                              board::kRadioBusy));

const uint32_t kRfSwitchPins[] = {RADIOLIB_LR11X0_DIO5, RADIOLIB_LR11X0_DIO6, RADIOLIB_NC,
                                  RADIOLIB_NC, RADIOLIB_NC};
const Module::RfSwitchMode_t kRfSwitchTable[] = {
    {LR11x0::MODE_STBY, {LOW, LOW}},  {LR11x0::MODE_RX, {HIGH, LOW}},
    {LR11x0::MODE_TX, {LOW, HIGH}},   {LR11x0::MODE_TX_HP, {LOW, HIGH}},
    {LR11x0::MODE_TX_HF, {LOW, LOW}}, {LR11x0::MODE_GNSS, {LOW, LOW}},
    {LR11x0::MODE_WIFI, {LOW, LOW}},  END_OF_MODE_TABLE,
};
Profile profile;
volatile bool packetFlag = false;
bool receiving = false;
uint32_t packetCount = 0;
String serialLine;

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
      "crc=%s boost=%s receiving=%s chip=lr1121 firmware=%s\n",
      profile.frequencyMhz, profile.bandwidthKhz, profile.spreadingFactor,
      profile.codingRate, profile.syncWord, profile.preambleSymbols,
      profile.crcEnabled ? "on" : "off", profile.boostedGain ? "on" : "off",
      receiving ? "yes" : "no", kFirmwareVersion);
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
  if (cmd == "version") { Serial.printf("zynq-lora-lilygo-lr1121-rx %s\n", kFirmwareVersion); return; }
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
                0.0F);
  for (size_t i = 0; i < length && i < kMaxPacket; ++i) Serial.printf("%02x", data[i]);
  Serial.println();
  board::setLed(true);
  delay(5);
  board::setLed(false);
  startReceiving();
}

}  // namespace

void setup() {
  pinMode(board::kLed, OUTPUT);
  board::setLed(false);

  Serial.begin(115200);
  const uint32_t start = millis();
  while (!Serial && millis() - start < 3000) delay(10);

  SPI.begin(board::kRadioSclk, board::kRadioMiso, board::kRadioMosi);
  delay(kRadioPowerUpDelayMs);

  Serial.printf("Initializing LILYGO T3-S3 LR1121 receiver firmware %s\n", kFirmwareVersion);
  const int16_t begin = radio.begin(profile.frequencyMhz, profile.bandwidthKhz,
                                    profile.spreadingFactor, profile.codingRate,
                                    profile.syncWord, 0, profile.preambleSymbols, 3.0F);
  radio.setRfSwitchTable(kRfSwitchPins, kRfSwitchTable);
  if (!ok(begin, "begin") || !apply(profile)) {
    Serial.println("FATAL radio initialization failed");
    while (true) { board::setLed(true); delay(100); board::setLed(false); delay(900); }
  }
  radio.setPacketReceivedAction(onPacket);
  Serial.println("READY receiver stopped; type 'rx start'");
  printProfile();
}

void loop() {
  serviceSerial();
  if (receiving) servicePacket();
  delay(1);
}
