"""Exercise the actual receiver loop against a deterministic radio stub."""
import shutil
import subprocess
from pathlib import Path

import pytest


def test_empty_recovery_restores_profile_counts_and_stops_on_failure(tmp_path):
    cc = shutil.which("g++")
    if not cc:
        pytest.skip("native C++ compiler required")
    root = Path(__file__).resolve().parents[1]
    (tmp_path / "Arduino.h").write_text(r'''
#pragma once
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#define HIGH 1
#define LOW 0
#define OUTPUT 1
inline void pinMode(int,int) {}
inline void digitalWrite(int,int) {}
inline void delay(unsigned) {}
inline uint32_t millis() { static uint32_t t; return ++t; }
struct String {
  std::string s;
  String(const char* p=""):s(p) {}
  String(std::string p):s(p) {}
  void trim() {}
  bool isEmpty() const { return s.empty(); }
  void toLowerCase() { std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return std::tolower(c);}); }
  bool startsWith(const char* p) const { return s.rfind(p,0)==0; }
  int indexOf(char c,int p) const { auto n=s.find(c,p); return n==s.npos?-1:static_cast<int>(n); }
  String substring(int a,int b) const { return s.substr(a,b-a); }
  String substring(int a) const { return s.substr(a); }
  float toFloat() const { return std::strtof(s.c_str(),nullptr); }
  int toInt() const { return std::atoi(s.c_str()); }
  const char* c_str() const { return s.c_str(); }
  size_t length() const { return s.size(); }
  bool operator==(const char* p) const { return s==p; }
  bool operator!=(const char* p) const { return s!=p; }
  String& operator+=(char c) { s+=c; return *this; }
};
struct SerialStub {
  std::string output;
  void begin(int) {}
  operator bool() const { return true; }
  int available() const { return 0; }
  int read() const { return 0; }
  void println(const char* p="") { output+=p; output+='\n'; }
  template<class... T> void printf(const char* f,T... args) {
    char b[1024]; std::snprintf(b,sizeof b,f,args...); output+=b;
  }
};
inline SerialStub Serial;
''', encoding="utf-8")
    (tmp_path / "SPI.h").write_text(
        "#pragma once\nstruct SPIStub { void begin(int,int,int) {} }; inline SPIStub SPI;\n")
    (tmp_path / "RadioLib.h").write_text(r'''
#pragma once
#include <cstddef>
#include <cstdint>
#define RADIOLIB_ERR_NONE 0
#define RADIOLIB_ERR_UNKNOWN -1
#define RADIOLIB_ERR_CRC_MISMATCH -7
#define RADIOLIB_NC 255
#define RADIOLIB_LR11X0_DIO5 5
#define RADIOLIB_LR11X0_DIO6 6
#define RADIOLIB_LR11X0_IRQ_RX_DONE 8
#define END_OF_MODE_TABLE {0,{0,0}}
struct Module {
  Module(int,int,int,int) {}
  struct RfSwitchMode_t { int mode; int pins[5]; };
};
struct LR11x0VersionInfo_t { uint8_t hardware,device,fwMajor,fwMinor; };
struct LR11x0 {
  enum { MODE_STBY,MODE_RX,MODE_TX,MODE_TX_HP,MODE_TX_HF,MODE_GNSS,MODE_WIFI };
};
struct LR1121:LR11x0 {
  explicit LR1121(Module*) {}
  uint8_t chipType=3;
  unsigned begins=0,starts=0,actions=0,switches=0;
  size_t packetLength=0;
  bool failBegin=false;
  float freq=0,bw=0;
  uint8_t sf=0,cr=0,sync=0,crc=0;
  uint16_t preamble=0;
  bool boost=false,ldro=false;
  int16_t begin(float,float,uint8_t,uint8_t,uint8_t,int,uint16_t,float) {
    ++begins; freq=bw=0; sf=cr=sync=crc=0; preamble=0; boost=ldro=false;
    return failBegin?-1:0;
  }
  void standby() {}
  int16_t setFrequency(float v) { freq=v; return 0; }
  int16_t setBandwidth(float v) { bw=v; return 0; }
  int16_t setSpreadingFactor(uint8_t v) { sf=v; return 0; }
  int16_t setCodingRate(uint8_t v) { cr=v; return 0; }
  int16_t forceLDRO(bool v) { ldro=v; return 0; }
  int16_t setSyncWord(uint8_t v) { sync=v; return 0; }
  int16_t setPreambleLength(uint16_t v) { preamble=v; return 0; }
  int16_t setCRC(uint8_t v) { crc=v; return 0; }
  int16_t setRxBoostedGainMode(bool v) { boost=v; return 0; }
  void setRfSwitchTable(const uint32_t*,const Module::RfSwitchMode_t*) { ++switches; }
  void setPacketReceivedAction(void(*)()) { ++actions; }
  int16_t startReceive() { ++starts; return 0; }
  uint32_t getIrqStatus() { return RADIOLIB_LR11X0_IRQ_RX_DONE; }
  size_t getPacketLength(bool,uint8_t* p) { *p=0; return packetLength; }
  int16_t getLoRaRxHeaderInfo(void*,bool* p) { *p=true; return 0; }
  int16_t readData(uint8_t*,size_t) { return 0; }
  float getRSSI() { return -90; }
  float getSNR() { return 10; }
 protected:
  int16_t getVersion(uint8_t* h,uint8_t* d,uint8_t* a,uint8_t* b) {
    *h=0x22; *d=0xF3; *a=1; *b=4; return 0;
  }
};
''', encoding="utf-8")
    source = root / "firmware/lilygo-t3s3-lr1121-rx/src/main.cpp"
    driver = tmp_path / "recovery.cpp"
    driver.write_text(f'#include "{source.as_posix()}"\n' + r'''
#include <cassert>
int main() {
  profile.frequencyMhz=868.3F; profile.bandwidthKhz=500;
  profile.spreadingFactor=6; profile.codingRate=8; profile.syncWord=0x34;
  profile.preambleSymbols=16; profile.crcEnabled=true; profile.boostedGain=true;
  assert(initializeRadio()); startReceiving();
  assert(radioVersionState==0 && radioVersion.device==0xF3);
  radio.packetLength=32; packetFlag=true; servicePacket();
  assert(radio.begins==1 && packetCount==1 && emptyRecoveries==0);
  emptyRecovery=false; radio.packetLength=0; packetFlag=true; servicePacket();
  assert(radio.begins==1 && packetCount==2 && emptyRecoveries==0);
  emptyRecovery=true; packetFlag=true; servicePacket();
  assert(radio.begins==2 && packetCount==3 && emptyRecoveries==1 && receiving);
  assert(radio.freq==868.3F && radio.bw==500 && radio.sf==6 && radio.cr==8);
  assert(radio.sync==0x34 && radio.preamble==16 && radio.crc==2 && radio.boost && !radio.ldro);
  assert(radio.switches==2 && radio.actions==2);
  assert(Serial.output.find("len=0")!=std::string::npos);
  assert(Serial.output.find("RECOVERY reason=empty_rx count=1 ready=1")!=std::string::npos);
  unsigned starts=radio.starts; radio.failBegin=true; packetFlag=true; servicePacket();
  assert(packetCount==4 && emptyRecoveries==2 && !receiving && radio.starts==starts);
  assert(Serial.output.find("ready=0")!=std::string::npos);
  radio.failBegin=false; startReceiving(); handle("reset radio");
  assert(receiving && packetCount==4 && emptyRecoveries==2 && radio.sf==6 && radio.cr==8);
  handle("reset count"); assert(packetCount==0 && emptyRecoveries==0);
}
''', encoding="utf-8")
    binary = tmp_path / "recovery"
    subprocess.run([cc, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    "-I", str(tmp_path), "-I", str(root / "firmware/lilygo-t3s3-lr1121-tx/include"),
                    str(driver), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
