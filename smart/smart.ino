// ============================================================
//  SMART FAN v4.2 — MERGED
//  Base : Doc3 (v4.2) full logic — Firebase, 5-mode cycling,
//         swingType L<>R / L<>C / R<>C, setMistLevel()
//  Pins : Doc4 calibration (PIR=14/27/26, BTN_SWING=34, BTN_MIST=35)
//  Fixed: ledcAttach() used (Core v3 style — matches Doc4 setup)
// ============================================================
//
//  ┌─────────────────────────────────────────────────────────┐
//  │                 CALIBRATION QUICK GUIDE                 │
//  │  Search the tag shown to jump to that value in code     │
//  ├──────────────────────────┬──────────────────────────────┤
//  │  PIR warm-up time        │  TAG: CAL_PIR_WARMUP         │
//  │  Fan idle timeout        │  TAG: CAL_IDLE_TIMEOUT       │
//  │  Temp→speed thresholds   │  TAG: CAL_TEMP_SPEED         │
//  │  Manual speed PWM values │  TAG: CAL_MANUAL_SPEEDS      │
//  │  Swing step distance     │  TAG: CAL_STEPS_PER_90       │
//  │  Swing step pulse speed  │  TAG: CAL_STEP_PULSE         │
//  │  Swing interval (ms)     │  TAG: CAL_SWING_INTERVAL     │
//  │  Button debounce (ms)    │  TAG: CAL_DEBOUNCE           │
//  │  Firebase push interval  │  TAG: CAL_PUSH_INTERVAL      │
//  │  Firebase poll interval  │  TAG: CAL_POLL_INTERVAL      │
//  └──────────────────────────┴──────────────────────────────┘
//
// ============================================================
//  COMPLETE PIN MAP
// ============================================================
//  TFT SPI : CS=2   DC=16  RST=17  SCK=18  MOSI=23
//  DHT22   : 4
//  PIR     : LEFT=14  CENTER=27  RIGHT=26   ← Doc4 pins
//  MOTOR   : IN1=25  IN2=33  ENA=5
//  STEPPER : STEP=32  DIR=15
//  RELAY   : R1=21  R2=22  R4(LIGHT)=19
//  BUTTONS : MODE=12  SPEED=13  SWING=34  MIST=35  ← Doc4 pins
//  NOTE    : GPIO 34/35 are input-only — no internal pull-up.
//            Wire external 10kΩ resistors from GPIO34/35 to 3.3V.
//            Buttons connect GPIO to GND (active LOW).
// ============================================================

#include "DHT.h"
#include "addons/TokenHelper.h"
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <Firebase_ESP_Client.h>
#include <SPI.h>
#include <WiFi.h>

// ── PIR sensors ──────────────────────────────────────────────
#define PIR_LEFT 14 // ← Doc4 pin
#define PIR_CENTER 34
#define PIR_RIGHT 35 // ← Doc4 pin

// ── DHT22 ────────────────────────────────────────────────────
#define DHTPIN 4
#define DHTTYPE DHT22
DHT dht(DHTPIN, DHTTYPE);

// ── Fan motor (L298N) ────────────────────────────────────────
#define IN1 25
#define IN2 33
#define ENA 5

// ── Stepper (TB6600 / A4988) ─────────────────────────────────
#define STEP_PIN 32
#define DIR_PIN 15

// ── Relays (ACTIVE LOW) ───────────────────────────────────────
#define RELAY1 21
#define RELAY2 22
#define RELAY4 0 // Light relay

// ── TFT display ──────────────────────────────────────────────
#define TFT_CS 2
#define TFT_DC 16
#define TFT_RST 17
Adafruit_ST7735 tft = Adafruit_ST7735(TFT_CS, TFT_DC, TFT_RST);

// ── Buttons ──────────────────────────────────────────────────
#define BTN_MODE 12  // INPUT_PULLUP
#define BTN_SPEED 13 // INPUT_PULLUP
#define BTN_SWING 26 // ← Doc4 pin  — INPUT only, ext 10kΩ pull-up to 3.3V
#define BTN_MIST 27  // ← Doc4 pin  — INPUT only, ext 10kΩ pull-up to 3.3V

// ============================================================
//  COLOUR PALETTE
// ============================================================
#define C_BG 0x0841
#define C_PANEL 0x1082
#define C_BORDER 0x4228
#define C_ACCENT 0xF600
#define C_GREEN 0x07E0
#define C_RED 0xF800
#define C_CYAN 0x07FF
#define C_WHITE 0xFFFF
#define C_DIMWHITE 0xC618
#define C_YELLOW 0xFFE0
#define C_ORANGE 0xFC00
#define C_PURPLE 0x780F
#define C_BLUE 0x001F
#define C_TEAL 0x0410

// ============================================================
//  WIFI + FIREBASE CONFIG  — CHANGE THESE!
// ============================================================
#define WIFI_SSID "AUSTUDENT"
#define WIFI_PASSWORD "4592cdef0912"
#define API_KEY "AIzaSyCGqJID6M-Riw0yTpcx6CA36PdZcl8UX5Q"
#define FIREBASE_PROJECT_ID "smart-6d1d2"
#define DEVICE_ID "smartfan001"
#define PAIRING_CODE "FAN123"

FirebaseData fbData;
FirebaseAuth fbAuth;
FirebaseConfig fbConfig;
bool firebaseReady = false;

// CAL_PUSH_INTERVAL — how often status is sent to Firebase (ms)
// Increase if you hit Firebase rate limits. Decrease for faster app refresh.
const unsigned long PUSH_INTERVAL = 1000;

// CAL_POLL_INTERVAL — how often app commands are checked (ms)
// Lower = faster response to app commands. Min safe value ~300ms.
const unsigned long POLL_INTERVAL = 500;

unsigned long lastPushTime = 0;
unsigned long lastPollTime = 0;

// ============================================================
//  PRESETS & MODE STATE
// ============================================================
enum PresetMode { PRESET_NONE = 0, PRESET_TRAVEL, PRESET_OFFICE, PRESET_NIGHT };
PresetMode currentPreset = PRESET_NONE;
const char *presetNames[] = {"NONE", "TRAVEL", "OFFICE", "NIGHT"};

// currentModeIndex: 0=AUTO  1=MANUAL  2=TRAVEL  3=OFFICE  4=NIGHT
int currentModeIndex = 0;

// ============================================================
//  STEPPER CALIBRATION
// ============================================================
// CAL_STEPS_PER_90 — steps for 90° of swing travel.
// Increase = wider swing angle. Decrease = narrower swing.
// Doc4 uses 900 (5000µs pulse), Doc3 uses 200 (1500µs pulse).
// With faster pulses (1500µs) you need fewer steps for same angle.
int stepsPer90 = 1200;   // ← same as Doc4
int currentPosition = 0; // -1=LEFT  0=CENTER  1=RIGHT

// CAL_STEP_PULSE — delay between step pulses in microseconds.
// Lower = faster stepper movement. Min safe value depends on driver/motor.
// Doc4: 5000µs  Doc3: 1500µs
#define STEP_PULSE_US 3000 // ← same as Doc4

// CAL_SWING_INTERVAL — time (ms) between each swing direction change.
// Increase = slower swing back-and-forth. Decrease = faster.
const int swingInterval = 3000; // ← Doc4 value (Doc3 used 1500)

// ============================================================
//  TIMING & BEHAVIOUR CALIBRATION
// ============================================================
// CAL_IDLE_TIMEOUT — how long (ms) after last human detection before fan stops.
const unsigned long RUN_DURATION = 30000; // 30 seconds

// CAL_DEBOUNCE — button debounce time (ms). Increase if buttons double-trigger.
const unsigned long DEBOUNCE_MS = 500; // ← Doc4 value (proven)
const unsigned long HOLD_MS = 1000;

// ============================================================
//  RUNTIME STATE
// ============================================================
unsigned long runStartTime = 0;
bool fanRunning = false;

bool swingMode = false;
bool swingDirection = false;
unsigned long lastSwingTime = 0;
int swingType = 0; // 0=none  1=L<>R  2=L<>C  3=R<>C

String mistState = "OFF";
int mistLevel = 0; // 0=OFF  1=LOW  2=ALL
String modeState = "CENTER";
bool lightOn = false;

bool isAutoMode = true;
int manualSpeedLevel = 0;
bool manualMistOn = false;

// CAL_MANUAL_SPEEDS — PWM values for LOW / MED / HI manual speed.
// Range 0–255. Increase HI if fan feels weak. Decrease LOW if too loud at
// minimum.
const int manualSpeeds[3] = {160, 200, 255};
const char *manualSpeedNames[3] = {"LOW", "MED", "HI "};

// ── Display dirty flags ───────────────────────────────────────
float lastTemp = -999;
int lastSpeed = -1;
String lastMist = "";
String lastDir = "";
bool lastSwing = false;
bool lastAuto = true;
bool firstDraw = true;
PresetMode lastPreset = PRESET_NONE;
bool lastLight = false;

// ── Button state tracking ─────────────────────────────────────
unsigned long lastModeBtnTime = 0;
unsigned long lastSpeedBtnTime = 0;
unsigned long lastSwingBtnTime = 0;
unsigned long lastMistBtnTime = 0;
unsigned long modeBtnPressTime = 0;
bool modeBtnHandled = false;
int lastModeBtnState = HIGH;
int lastSpeedBtnState = HIGH;
int lastSwingBtnState = HIGH;
int lastMistBtnState = HIGH;

unsigned long bootTime = 0;

// ============================================================
//  FORWARD DECLARATIONS
// ============================================================
void applyModeByIndex(int idx);
void applyPreset(PresetMode p);
void lightON();
void lightOFF();
void setMistLevel(int lv);
void setMistAll(bool on);
void moveLeft();
void moveRight();
void moveToCenter();

// ============================================================
//  STEPPER
// ============================================================
void stepMotor(int steps, bool dir) {
  digitalWrite(DIR_PIN, dir);
  for (int i = 0; i < steps; i++) {
    digitalWrite(STEP_PIN, HIGH);
    delayMicroseconds(STEP_PULSE_US);
    digitalWrite(STEP_PIN, LOW);
    delayMicroseconds(STEP_PULSE_US);
  }
}
void moveLeft() {
  // Travel depends on where we currently are
  if (currentPosition == 0)
    stepMotor(stepsPer90, false); // CENTER→LEFT
  else if (currentPosition == 1)
    stepMotor(stepsPer90 * 2, false); // RIGHT→LEFT (double steps)
  // if already -1, don't move
  if (currentPosition != -1)
    currentPosition = -1;
}

void moveRight() {
  if (currentPosition == 0)
    stepMotor(stepsPer90, true); // CENTER→RIGHT
  else if (currentPosition == -1)
    stepMotor(stepsPer90 * 2, true); // LEFT→RIGHT (double steps)
  if (currentPosition != 1)
    currentPosition = 1;
}

void moveToCenter() {
  if (currentPosition == -1)
    stepMotor(stepsPer90, true); // LEFT→CENTER
  else if (currentPosition == 1)
    stepMotor(stepsPer90, false); // RIGHT→CENTER
  currentPosition = 0;
}

// ============================================================
//  LIGHT
// ============================================================
void lightON() {
  lightOn = true;
  digitalWrite(RELAY4, LOW);
  firstDraw = true;
  Serial.println(">> Light ON");
}
void lightOFF() {
  lightOn = false;
  digitalWrite(RELAY4, HIGH);
  firstDraw = true;
  Serial.println(">> Light OFF");
}

// ============================================================
//  MIST
// ============================================================
// setMistLevel: 0=OFF  1=LOW (RELAY1 only)  2=ALL (both relays)
void setMistLevel(int lv) {
  mistLevel = constrain(lv, 0, 2);
  switch (mistLevel) {
  case 0:
    digitalWrite(RELAY1, HIGH);
    digitalWrite(RELAY2, HIGH);
    mistState = "OFF";
    manualMistOn = false;
    break;
  case 1:
    digitalWrite(RELAY1, LOW);
    digitalWrite(RELAY2, HIGH);
    mistState = "LOW";
    manualMistOn = true;
    break;
  case 2:
    digitalWrite(RELAY1, LOW);
    digitalWrite(RELAY2, LOW);
    mistState = "ALL";
    manualMistOn = true;
    break;
  }
  firstDraw = true;
  Serial.print(">> Mist: ");
  Serial.println(mistState);
}

void setMistAll(bool on) { setMistLevel(on ? 2 : 0); }

// AUTO mode — ties mist level to fan speed
// CAL_TEMP_SPEED — also affects mist since mist follows speed in AUTO
void controlMistBySpeed(int speed) {
  if (speed == 160)
    setMistLevel(0);
  else if (speed == 200)
    setMistLevel(1);
  else
    setMistLevel(2);
}

// ============================================================
//  PRESETS
// ============================================================
void applyPreset(PresetMode p) {
  currentPreset = p;
  firstDraw = true;
  if (p == PRESET_TRAVEL)
    currentModeIndex = 2;
  else if (p == PRESET_OFFICE)
    currentModeIndex = 3;
  else if (p == PRESET_NIGHT)
    currentModeIndex = 4;
  else
    currentModeIndex = 0;

  switch (p) {
  case PRESET_TRAVEL:
    isAutoMode = false;
    fanRunning = true;
    manualSpeedLevel = 0;
    swingMode = false;
    swingType = 0;
    manualMistOn = false;
    setMistAll(false);
    lightOFF();
    moveToCenter();
    modeState = "CENTER";
    Serial.println("[PRESET] TRAVEL");
    break;
  case PRESET_OFFICE:
    isAutoMode = true;
    fanRunning = false;
    swingMode = false;
    swingType = 0;
    manualMistOn = false;
    setMistAll(false);
    lightOFF();
    moveToCenter();
    modeState = "CENTER";
    Serial.println("[PRESET] OFFICE");
    break;
  case PRESET_NIGHT:
    isAutoMode = false;
    fanRunning = true;
    manualSpeedLevel = 0;
    swingMode = false;
    swingType = 0;
    manualMistOn = false;
    setMistAll(false);
    lightON();
    moveToCenter();
    modeState = "CENTER";
    Serial.println("[PRESET] NIGHT");
    break;
  default:
    isAutoMode = true;
    fanRunning = false;
    swingMode = false;
    swingType = 0;
    setMistAll(false);
    lightOFF();
    moveToCenter();
    modeState = "CENTER";
    Serial.println("[PRESET] NONE");
    break;
  }
}

// ============================================================
//  MODE CYCLING — BTN_MODE short press cycles all 5 modes
//  0=AUTO  1=MANUAL  2=TRAVEL  3=OFFICE  4=NIGHT
// ============================================================
void applyModeByIndex(int idx) {
  currentModeIndex = idx;
  firstDraw = true;
  switch (idx) {
  case 0: // AUTO
    currentPreset = PRESET_NONE;
    isAutoMode = true;
    fanRunning = false;
    swingMode = false;
    swingType = 0;
    manualMistOn = false;
    moveToCenter();
    modeState = "CENTER";
    setMistAll(false);
    digitalWrite(IN1, LOW);
    digitalWrite(IN2, LOW);
    ledcWrite(ENA, 0);
    Serial.println("[MODE] AUTO");
    break;
  case 1: // MANUAL
    currentPreset = PRESET_NONE;
    isAutoMode = false;
    fanRunning = true;
    manualSpeedLevel = 0;
    Serial.println("[MODE] MANUAL");
    break;
  case 2:
    applyPreset(PRESET_TRAVEL);
    break;
  case 3:
    applyPreset(PRESET_OFFICE);
    break;
  case 4:
    applyPreset(PRESET_NIGHT);
    break;
  }
}

// ============================================================
//  CLOUD — setup
// ============================================================
void setupCloud() {
  Serial.print("[WiFi] Connecting to ");
  Serial.println(WIFI_SSID);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 20) {
    delay(500);
    Serial.print(".");
    attempts++;
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("\n[WiFi] Connected! IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("\n[WiFi] FAILED — running offline");
    return;
  }
  fbConfig.api_key = API_KEY;
  fbAuth.user.email = "";
  fbAuth.user.password = "";
  fbConfig.token_status_callback = tokenStatusCallback;
  Firebase.signUp(&fbConfig, &fbAuth, "", "");
  Firebase.begin(&fbConfig, &fbAuth);
  Firebase.reconnectNetwork(true);
  firebaseReady = true;
  FirebaseJson json;
  json.set("fields/pairingCode/stringValue", PAIRING_CODE);
  json.set("fields/paired/booleanValue", false);
  json.set("fields/ownerId/stringValue", "");
  Firebase.Firestore.createDocument(&fbData, FIREBASE_PROJECT_ID, "",
                                    "devices/" DEVICE_ID, json.raw());
  Serial.println("[Firebase] Ready");
}

// ============================================================
//  CLOUD — push status
// ============================================================
void pushStatus(float temp, int speed, int pirL, int pirC, int pirR) {
  if (!firebaseReady || WiFi.status() != WL_CONNECTED)
    return;
  if (millis() - lastPushTime < PUSH_INTERVAL)
    return;
  lastPushTime = millis();

  const char *modeNames[] = {"AUTO", "MANUAL", "TRAVEL", "OFFICE", "NIGHT"};
  String c = "{\"fields\":{\"status\":{\"mapValue\":{\"fields\":{";
  c += "\"mode\":{\"stringValue\":\"" + String(modeNames[currentModeIndex]) +
       "\"},";
  c += "\"fanRunning\":{\"booleanValue\":" +
       String(fanRunning ? "true" : "false") + "},";
  c += "\"temperature\":{\"doubleValue\":" + String(temp, 1) + "},";
  c += "\"speed\":{\"integerValue\":\"" + String(speed) + "\"},";
  c += "\"mistState\":{\"stringValue\":\"" + mistState + "\"},";
  c += "\"lightOn\":{\"booleanValue\":" + String(lightOn ? "true" : "false") +
       "},";
  c += "\"swingMode\":{\"booleanValue\":" +
       String(swingMode ? "true" : "false") + "},";
  c += "\"direction\":{\"stringValue\":\"" + modeState + "\"},";
  c += "\"pirL\":{\"booleanValue\":" + String(pirL ? "true" : "false") + "},";
  c += "\"pirC\":{\"booleanValue\":" + String(pirC ? "true" : "false") + "},";
  c += "\"pirR\":{\"booleanValue\":" + String(pirR ? "true" : "false") + "},";
  c += "\"uptime\":{\"integerValue\":\"" +
       String((int)((millis() - bootTime) / 1000)) + "\"}";
  c += "}}}}}";

  if (!Firebase.Firestore.patchDocument(&fbData, FIREBASE_PROJECT_ID, "",
                                        "devices/" DEVICE_ID, c.c_str(),
                                        "status")) {
    Serial.print("[Cloud] Push FAILED: ");
    Serial.println(fbData.errorReason());
  }
}

// ============================================================
//  CLOUD — process command
// ============================================================
void processCloudCommand(String cmd) {
  cmd.toUpperCase();
  Serial.print("[CLOUD CMD] ");
  Serial.println(cmd);
  if (cmd == "AUTO")
    applyModeByIndex(0);
  else if (cmd == "MANUAL")
    applyModeByIndex(1);
  else if (cmd == "TRAVEL")
    applyModeByIndex(2);
  else if (cmd == "OFFICE")
    applyModeByIndex(3);
  else if (cmd == "NIGHT")
    applyModeByIndex(4);
  else if (cmd == "FAN_ON") {
    fanRunning = true;
  } else if (cmd == "FAN_OFF") {
    fanRunning = false;
    digitalWrite(IN1, LOW);
    digitalWrite(IN2, LOW);
    ledcWrite(ENA, 0);
  } else if (cmd == "DIR_LEFT") {
    if (!isAutoMode) {
      swingMode = false;
      swingType = 0;
      moveLeft();
      modeState = "LEFT";
      firstDraw = true;
    }
  } else if (cmd == "DIR_CENTER") {
    if (!isAutoMode) {
      swingMode = false;
      swingType = 0;
      moveToCenter();
      modeState = "CENTER";
      firstDraw = true;
    }
  } else if (cmd == "DIR_RIGHT") {
    if (!isAutoMode) {
      swingMode = false;
      swingType = 0;
      moveRight();
      modeState = "RIGHT";
      firstDraw = true;
    }
  } else if (cmd == "SPEED+") {
    if (!isAutoMode)
      manualSpeedLevel = min(manualSpeedLevel + 1, 2);
  } else if (cmd == "SPEED-") {
    if (!isAutoMode)
      manualSpeedLevel = max(manualSpeedLevel - 1, 0);
  } else if (cmd == "SWING_LR") {
    if (!isAutoMode) {
      swingType = 1;
      swingMode = true;
      modeState = "SWING";
      lastSwingTime = millis();
      swingDirection = false;
      firstDraw = true;
    }
  } else if (cmd == "SWING_LC") {
    if (!isAutoMode) {
      swingType = 2;
      swingMode = true;
      modeState = "L-C";
      lastSwingTime = millis();
      swingDirection = false;
      firstDraw = true;
    }
  } else if (cmd == "SWING_RC") {
    if (!isAutoMode) {
      swingType = 3;
      swingMode = true;
      modeState = "R-C";
      lastSwingTime = millis();
      swingDirection = false;
      firstDraw = true;
    }
  } else if (cmd == "SWING_OFF") {
    if (!isAutoMode) {
      swingType = 0;
      swingMode = false;
      moveToCenter();
      modeState = "CENTER";
      firstDraw = true;
    }
  } else if (cmd == "SWING_TOGGLE") {
    if (!isAutoMode) {
      swingMode = !swingMode;
      if (swingMode) {
        swingType = 1;
        modeState = "SWING";
        lastSwingTime = millis();
      } else {
        swingType = 0;
        moveToCenter();
        modeState = "CENTER";
      }
      firstDraw = true;
    }
  } else if (cmd == "LIGHT_ON")
    lightON();
  else if (cmd == "LIGHT_OFF")
    lightOFF();
  else if (cmd == "MIST_ON")
    setMistLevel(2);
  else if (cmd == "MIST_OFF")
    setMistLevel(0);
  else if (cmd == "MIST+")
    setMistLevel(mistLevel + 1);
  else if (cmd == "MIST-")
    setMistLevel(mistLevel - 1);
}

// ============================================================
//  CLOUD — poll command
// ============================================================
void pollCloudCommand() {
  if (!firebaseReady || WiFi.status() != WL_CONNECTED)
    return;
  if (millis() - lastPollTime < POLL_INTERVAL)
    return;
  lastPollTime = millis();

  if (Firebase.Firestore.getDocument(&fbData, FIREBASE_PROJECT_ID, "",
                                     "devices/" DEVICE_ID)) {
    FirebaseJson json;
    json.setJsonData(fbData.payload());
    FirebaseJsonData data;
    String cmdType = "";
    bool processed = true;
    if (json.get(data, "fields/command/mapValue/fields/type/stringValue"))
      cmdType = data.stringValue;
    if (json.get(data, "fields/command/mapValue/fields/processed/booleanValue"))
      processed = data.boolValue;
    if (!processed && cmdType.length() > 0) {
      processCloudCommand(cmdType);
      String ack = "{\"fields\":{\"command\":{\"mapValue\":{\"fields\":{";
      ack += "\"type\":{\"stringValue\":\"" + cmdType + "\"},";
      ack += "\"processed\":{\"booleanValue\":true}";
      ack += "}}}}}";
      Firebase.Firestore.patchDocument(&fbData, FIREBASE_PROJECT_ID, "",
                                       "devices/" DEVICE_ID, ack.c_str(),
                                       "command");
    }
  } else {
    Serial.print("[Cloud] Poll failed: ");
    Serial.println(fbData.errorReason());
  }
}

// ============================================================
//  TFT DASHBOARD
// ============================================================
void drawChrome() {
  tft.fillScreen(C_BG);
  tft.fillRect(0, 0, 160, 13, C_PANEL);
  tft.drawRect(0, 0, 160, 128, C_BORDER);
  tft.setTextSize(1);
  tft.setTextColor(C_ACCENT);
  tft.setCursor(3, 3);
  tft.print("\x10 SMART FAN v4.2");
  tft.drawFastHLine(0, 13, 160, C_BORDER);
  tft.drawFastHLine(0, 51, 160, C_BORDER);
  tft.drawFastHLine(0, 81, 160, C_BORDER);
  tft.drawFastHLine(0, 101, 160, C_BORDER);
  tft.drawFastVLine(39, 13, 38, C_BORDER);
  tft.drawFastVLine(79, 13, 38, C_BORDER);
  tft.drawFastVLine(119, 13, 38, C_BORDER);
  tft.drawFastVLine(88, 51, 30, C_BORDER);
  tft.setTextColor(C_DIMWHITE);
  tft.setCursor(2, 15);
  tft.print("TEMP");
  tft.setCursor(41, 15);
  tft.print("SPD");
  tft.setCursor(81, 15);
  tft.print("MIST");
  tft.setCursor(121, 15);
  tft.print("LGT");
  tft.setCursor(2, 53);
  tft.print("DIRECTION");
  tft.setCursor(91, 53);
  tft.print("SWING");
  tft.setCursor(2, 83);
  tft.print("PIR");
  tft.setCursor(90, 83);
  tft.print("PRESET");
  tft.setCursor(2, 103);
  tft.print("PWM");
  tft.setCursor(55, 103);
  tft.print("FAN");
  tft.setCursor(100, 103);
  tft.print("UPTIME");
}

void clearZone(int x, int y, int w, int h) { tft.fillRect(x, y, w, h, C_BG); }

void drawModeBadge(bool autoMode, PresetMode preset) {
  clearZone(100, 2, 58, 10);
  tft.setTextSize(1);
  uint16_t col;
  const char *label;
  if (preset == PRESET_TRAVEL) {
    col = C_BLUE;
    label = "TRAVEL";
  } else if (preset == PRESET_OFFICE) {
    col = C_TEAL;
    label = "OFFICE";
  } else if (preset == PRESET_NIGHT) {
    col = C_PURPLE;
    label = " NIGHT";
  } else if (autoMode) {
    col = C_GREEN;
    label = "  AUTO";
  } else {
    col = C_ORANGE;
    label = "MANUAL";
  }
  tft.fillRoundRect(101, 2, 57, 10, 2, col);
  tft.setTextColor(C_BG);
  tft.setCursor(104, 3);
  tft.print(label);
}

void drawTemp(float temp) {
  clearZone(1, 24, 37, 26);
  if (isnan(temp)) {
    tft.setTextSize(1);
    tft.setTextColor(C_RED);
    tft.setCursor(3, 30);
    tft.print("ERR");
  } else {
    // CAL_TEMP_SPEED — colour thresholds match speed thresholds below
    uint16_t col = (temp >= 35)   ? C_RED
                   : (temp >= 30) ? C_ORANGE
                   : (temp >= 25) ? C_YELLOW
                                  : C_CYAN;
    tft.setTextColor(col);
    tft.setTextSize(1);
    tft.setCursor(2, 25);
    tft.print(temp, 1);
    tft.setTextColor(C_DIMWHITE);
    tft.setCursor(2, 38);
    tft.print("degC");
  }
}

void drawSpeedCell(int speed, int lvl, bool autoMode) {
  clearZone(40, 24, 38, 26);
  tft.setTextSize(1);
  if (speed == 0) {
    tft.setTextColor(C_DIMWHITE);
    tft.setCursor(42, 25);
    tft.print("OFF");
    tft.fillRect(41, 37, 36, 4, C_PANEL);
    return;
  }
  uint16_t col = (speed >= 255) ? C_RED : (speed >= 200) ? C_ORANGE : C_GREEN;
  tft.setTextColor(col);
  tft.setCursor(42, 25);
  tft.print(autoMode ? "AUTO" : manualSpeedNames[lvl]);
  tft.fillRect(41, 37, 36, 4, C_PANEL);
  int bw = (speed == 160) ? 12 : (speed == 200) ? 24 : 36;
  tft.fillRect(41, 37, bw, 4, col);
}

void drawMistCell(String mist) {
  clearZone(80, 24, 38, 26);
  tft.setTextSize(1);
  uint16_t col = (mist == "ALL")   ? C_CYAN
                 : (mist == "LOW") ? C_YELLOW
                                   : C_DIMWHITE;
  tft.setTextColor(col);
  tft.setCursor(82, 25);
  tft.print(mist);
}

void drawLightCell(bool on) {
  clearZone(120, 24, 39, 26);
  tft.setTextSize(1);
  tft.setCursor(122, 25);
  if (on) {
    tft.setTextColor(C_YELLOW);
    tft.print("\x0F ON");
    tft.fillRect(121, 37, 37, 4, C_YELLOW);
  } else {
    tft.setTextColor(C_DIMWHITE);
    tft.print("OFF");
    tft.fillRect(121, 37, 37, 4, C_PANEL);
  }
}

void drawDirection(String dir) {
  clearZone(1, 62, 86, 18);
  uint16_t col;
  String sym;
  if (dir == "LEFT") {
    col = C_CYAN;
    sym = "\x11 LEFT   ";
  } else if (dir == "RIGHT") {
    col = C_CYAN;
    sym = "  RIGHT \x10";
  } else if (dir == "SWING") {
    col = C_ORANGE;
    sym = "\x11SWING\x10 ";
  } else if (dir == "L-C") {
    col = C_YELLOW;
    sym = "\x11 L<>C  ";
  } else if (dir == "R-C") {
    col = C_YELLOW;
    sym = "  C<>R \x10";
  } else {
    col = C_GREEN;
    sym = " CENTER   ";
  }
  tft.setTextColor(col);
  tft.setTextSize(1);
  tft.setCursor(3, 63);
  tft.print(sym);
  tft.fillRect(3, 73, 82, 4, C_PANEL);
  if (dir == "LEFT")
    tft.fillRect(3, 73, 22, 4, col);
  else if (dir == "RIGHT")
    tft.fillRect(62, 73, 22, 4, col);
  else if (dir == "SWING")
    tft.fillRect(3, 73, 82, 4, col);
  else if (dir == "L-C")
    tft.fillRect(3, 73, 42, 4, col);
  else if (dir == "R-C")
    tft.fillRect(42, 73, 42, 4, col);
  else
    tft.fillRect(32, 73, 22, 4, col);
}

void drawSwingCell(bool swing) {
  clearZone(89, 62, 70, 18);
  tft.setTextSize(1);
  tft.setCursor(91, 63);
  if (swing) {
    tft.setTextColor(C_GREEN);
    tft.print("\x07\x07\x07 ON");
  } else {
    tft.setTextColor(C_DIMWHITE);
    tft.print("--- OFF");
  }
  tft.fillRect(91, 73, 67, 4, C_PANEL);
  if (swing)
    tft.fillRect(91, 73, 67, 4, C_GREEN);
}

void drawPIRRow(int l, int c, int r, PresetMode preset) {
  clearZone(35, 84, 54, 15);
  tft.fillRoundRect(36, 84, 15, 13, 2, l ? C_GREEN : C_PANEL);
  tft.setTextColor(l ? C_BG : C_DIMWHITE);
  tft.setTextSize(1);
  tft.setCursor(39, 87);
  tft.print("L");
  tft.fillRoundRect(54, 84, 15, 13, 2, c ? C_GREEN : C_PANEL);
  tft.setTextColor(c ? C_BG : C_DIMWHITE);
  tft.setCursor(57, 87);
  tft.print("C");
  tft.fillRoundRect(72, 84, 15, 13, 2, r ? C_GREEN : C_PANEL);
  tft.setTextColor(r ? C_BG : C_DIMWHITE);
  tft.setCursor(75, 87);
  tft.print("R");
  clearZone(90, 84, 68, 15);
  uint16_t pc;
  const char *pn;
  switch (preset) {
  case PRESET_TRAVEL:
    pc = C_BLUE;
    pn = "TRAVEL";
    break;
  case PRESET_OFFICE:
    pc = C_TEAL;
    pn = "OFFICE";
    break;
  case PRESET_NIGHT:
    pc = C_PURPLE;
    pn = "NIGHT ";
    break;
  default:
    pc = C_PANEL;
    pn = " NONE ";
    break;
  }
  tft.fillRoundRect(91, 85, 65, 12, 2, pc);
  tft.setTextColor(C_WHITE);
  tft.setTextSize(1);
  tft.setCursor(94, 88);
  tft.print(pn);
}

void drawStatusBar(int pwm, bool fanOn) {
  clearZone(1, 110, 158, 16);
  tft.setTextSize(1);
  tft.setTextColor(C_ACCENT);
  tft.setCursor(1, 111);
  tft.print("PWM:");
  tft.print(pwm);
  tft.setCursor(55, 111);
  tft.setTextColor(fanOn ? C_GREEN : C_RED);
  tft.print(fanOn ? "RUN" : "OFF");
  unsigned long upSec = (millis() - bootTime) / 1000;
  tft.setCursor(100, 111);
  tft.setTextColor(C_DIMWHITE);
  if (upSec < 3600) {
    tft.print(upSec);
    tft.print("s");
  } else {
    tft.print(upSec / 3600);
    tft.print("h");
  }
}

void updateDisplay(float temp, int speed, int pirL, int pirC, int pirR) {
  if (firstDraw) {
    drawChrome();
    firstDraw = false;
    lastPreset = (PresetMode)-1;
    lastAuto = !isAutoMode;
  }
  if (currentPreset != lastPreset || isAutoMode != lastAuto) {
    drawModeBadge(isAutoMode, currentPreset);
    lastPreset = currentPreset;
    lastAuto = isAutoMode;
  }
  if (abs(temp - lastTemp) > 0.2) {
    drawTemp(temp);
    lastTemp = temp;
  }
  if (speed != lastSpeed) {
    drawSpeedCell(speed, manualSpeedLevel, isAutoMode);
    lastSpeed = speed;
  }
  if (mistState != lastMist) {
    drawMistCell(mistState);
    lastMist = mistState;
  }
  if (lightOn != lastLight) {
    drawLightCell(lightOn);
    lastLight = lightOn;
  }
  if (modeState != lastDir) {
    drawDirection(modeState);
    lastDir = modeState;
  }
  if (swingMode != lastSwing) {
    drawSwingCell(swingMode);
    lastSwing = swingMode;
  }
  drawPIRRow(pirL, pirC, pirR, currentPreset);
  drawStatusBar(speed, fanRunning);
}

// ============================================================
//  SERIAL COMMANDS
// ============================================================
void handleSerial() {
  if (!Serial.available())
    return;
  String cmd = Serial.readStringUntil('\n');
  cmd.trim();
  cmd.toUpperCase();
  Serial.print("[CMD] ");
  Serial.println(cmd);

  if (cmd == "A" || cmd == "AUTO") {
    applyModeByIndex(0);
  }
  if (cmd == "M" || cmd == "MANUAL") {
    applyModeByIndex(1);
  }
  if (cmd == "+") {
    if (!isAutoMode) {
      manualSpeedLevel = min(manualSpeedLevel + 1, 2);
      Serial.print(">> Speed: ");
      Serial.println(manualSpeedNames[manualSpeedLevel]);
    } else
      Serial.println(">> Ignored (AUTO)");
  }
  if (cmd == "-") {
    if (!isAutoMode) {
      manualSpeedLevel = max(manualSpeedLevel - 1, 0);
      Serial.print(">> Speed: ");
      Serial.println(manualSpeedNames[manualSpeedLevel]);
    } else
      Serial.println(">> Ignored (AUTO)");
  }
  if (cmd == "SN" || cmd == "SWING ON") {
    if (!isAutoMode) {
      swingType = 1;
      swingMode = true;
      modeState = "SWING";
      lastSwingTime = millis();
      Serial.println(">> Swing L<>R ON");
    } else
      Serial.println(">> Ignored (AUTO)");
  }
  if (cmd == "SF" || cmd == "SWING OFF") {
    if (!isAutoMode) {
      swingType = 0;
      swingMode = false;
      moveToCenter();
      modeState = "CENTER";
      Serial.println(">> Swing OFF");
    } else
      Serial.println(">> Ignored (AUTO)");
  }
  if (cmd == "MI" || cmd == "MIST ON") {
    if (!isAutoMode)
      setMistLevel(2);
    else
      Serial.println(">> Ignored (AUTO)");
  }
  if (cmd == "MF" || cmd == "MIST OFF") {
    if (!isAutoMode)
      setMistLevel(0);
    else
      Serial.println(">> Ignored (AUTO)");
  }
  if (cmd == "LN" || cmd == "LIGHT ON") {
    lightON();
  }
  if (cmd == "LF" || cmd == "LIGHT OFF") {
    lightOFF();
  }
  if (cmd == "TM" || cmd == "TRAVEL") {
    applyPreset(PRESET_TRAVEL);
  }
  if (cmd == "OM" || cmd == "OFFICE") {
    applyPreset(PRESET_OFFICE);
  }
  if (cmd == "NM" || cmd == "NIGHT") {
    applyPreset(PRESET_NIGHT);
  }
  if (cmd == "PM" || cmd == "PRESET OFF") {
    applyPreset(PRESET_NONE);
  }
  if (cmd == "ST" || cmd == "STATUS") {
    Serial.println("====== STATUS v4.2 ======");
    Serial.print("Mode   : ");
    Serial.println(isAutoMode ? "AUTO" : "MANUAL");
    Serial.print("Preset : ");
    Serial.println(presetNames[currentPreset]);
    Serial.print("Fan    : ");
    Serial.println(fanRunning ? "ON" : "OFF");
    Serial.print("Speed  : ");
    Serial.println(manualSpeedNames[manualSpeedLevel]);
    Serial.print("Swing  : ");
    Serial.print(swingMode ? "ON" : "OFF");
    Serial.print("  Type:");
    Serial.println(swingType);
    Serial.print("Mist   : ");
    Serial.println(mistState);
    Serial.print("Light  : ");
    Serial.println(lightOn ? "ON" : "OFF");
    Serial.print("Dir    : ");
    Serial.println(modeState);
    Serial.print("Uptime : ");
    Serial.print((millis() - bootTime) / 1000);
    Serial.println("s");
    Serial.println("=========================");
  }
}

// ============================================================
//  BUTTONS
//  GPIO12 BTN_MODE  — INPUT_PULLUP, cycles 5 modes on release
//  GPIO13 BTN_SPEED — INPUT_PULLUP, cycles speed on press
//  GPIO34 BTN_SWING — INPUT only (ext pull-up), toggles swing on press
//  GPIO35 BTN_MIST  — INPUT only (ext pull-up), cycles mist on press
// ============================================================
void handleButtons() {
  unsigned long now = millis();

  // ── BTN_MODE — fire on release, cycles AUTO→MANUAL→TRAVEL→OFFICE→NIGHT ──
  int r1 = digitalRead(BTN_MODE);
  if (r1 == LOW && lastModeBtnState == HIGH) {
    modeBtnPressTime = now;
    modeBtnHandled = false;
  }
  if (r1 == HIGH && lastModeBtnState == LOW) {
    if (!modeBtnHandled && (now - modeBtnPressTime) >= DEBOUNCE_MS) {
      int nextIdx = (currentModeIndex + 1) % 5;
      applyModeByIndex(nextIdx);
      const char *mn[] = {"AUTO", "MANUAL", "TRAVEL", "OFFICE", "NIGHT"};
      Serial.print("[BTN1] Mode: ");
      Serial.println(mn[nextIdx]);
    }
  }
  lastModeBtnState = r1;

  // ── BTN_SPEED — fire on press edge ────────────────────────────────────────
  int r2 = digitalRead(BTN_SPEED);
  if (r2 == LOW && lastSpeedBtnState == HIGH &&
      (now - lastSpeedBtnTime) > DEBOUNCE_MS) {
    lastSpeedBtnTime = now;
    if (!isAutoMode) {
      manualSpeedLevel = (manualSpeedLevel + 1) % 3;
      Serial.print("[BTN2] Speed: ");
      Serial.println(manualSpeedNames[manualSpeedLevel]);
    }
  }
  lastSpeedBtnState = r2;

  // ── BTN_SWING (GPIO34, ext pull-up, active LOW) ────────────────────────────
  int r3 = digitalRead(BTN_SWING);
  if (r3 == LOW && lastSwingBtnState == HIGH &&
      (now - lastSwingBtnTime) > DEBOUNCE_MS) {
    lastSwingBtnTime = now;
    if (!isAutoMode) {
      swingMode = !swingMode;
      if (swingMode) {
        swingType = 1;
        modeState = "SWING";
        lastSwingTime = millis();
        Serial.println("[BTN3] Swing ON (L<>R)");
      } else {
        swingType = 0;
        moveToCenter();
        modeState = "CENTER";
        Serial.println("[BTN3] Swing OFF");
      }
      firstDraw = true;
    }
  }
  lastSwingBtnState = r3;

  // ── BTN_MIST (GPIO35, ext pull-up, active LOW) — cycles OFF→LOW→ALL→OFF ──
  int r4 = digitalRead(BTN_MIST);
  if (r4 == LOW && lastMistBtnState == HIGH &&
      (now - lastMistBtnTime) > DEBOUNCE_MS) {
    lastMistBtnTime = now;
    if (!isAutoMode) {
      setMistLevel((mistLevel + 1) % 3);
      Serial.print("[BTN4] Mist: ");
      Serial.println(mistState);
    }
  }
  lastMistBtnState = r4;
}

// ============================================================
//  CALIBRATION SCREEN
// ============================================================
void showCalibration() {
  tft.fillScreen(C_BG);
  tft.drawRect(2, 2, 156, 124, C_ACCENT);
  tft.drawRect(4, 4, 152, 120, C_BORDER);
  tft.fillRect(3, 3, 154, 18, C_PANEL);
  tft.setTextColor(C_ACCENT);
  tft.setTextSize(1);
  tft.setCursor(8, 8);
  tft.print("\x10 SMART FAN v4.2");
  tft.setTextColor(C_DIMWHITE);
  tft.setCursor(8, 26);
  tft.print("Mode    : AUTO");
  tft.setCursor(8, 36);
  tft.print("Serial  : 115200 baud");
  tft.setCursor(8, 46);
  tft.print("Presets : TM  OM  NM");
  tft.setCursor(8, 56);
  tft.print("BTN1 = Cycle 5 Modes");
  tft.setTextColor(C_CYAN);
  tft.setCursor(8, 68);
  tft.print("PIR CALIBRATING...");
  tft.drawRect(8, 80, 142, 10, C_BORDER);

  // CAL_PIR_WARMUP — PIR sensor warm-up countdown in seconds.
  // Most PIR modules need 30–60s on first power-up.
  // Increase to 60 if PIR gives false triggers at startup.
  for (int i = 30; i >= 1; i--) {
    int filled = map(30 - i, 0, 29, 0, 140);
    tft.fillRect(9, 81, filled, 8, C_GREEN);
    tft.fillRect(8, 94, 142, 14, C_BG);
    tft.setTextColor(C_WHITE);
    tft.setTextSize(1);
    tft.setCursor(8, 97);
    tft.print("Wait ");
    tft.print(i);
    tft.print("s...");
    Serial.print("Calibrating: ");
    Serial.print(i);
    Serial.println("s");

    // Handle serial commands even during calibration
    unsigned long waitEnd = millis() + 1000;
    while (millis() < waitEnd) {
      handleSerial();
      delay(20);
    }
  }
  tft.fillRect(8, 66, 142, 44, C_BG);
  tft.fillRect(8, 80, 142, 18, C_GREEN);
  tft.setTextColor(C_BG);
  tft.setTextSize(1);
  tft.setCursor(20, 86);
  tft.print("SYSTEM READY  v4.2");
  delay(900);
}

// ============================================================
//  SETUP
// ============================================================
void setup() {
  Serial.begin(115200);

  // PIR — input-only pins, PIR module actively drives HIGH/LOW
  pinMode(PIR_LEFT, INPUT);   // GPIO14
  pinMode(PIR_CENTER, INPUT); // GPIO27
  pinMode(PIR_RIGHT, INPUT);  // GPIO26

  // Buttons — MODE and SPEED have internal pull-up
  //           SWING and MIST use input-only GPIOs with EXT pull-up
  pinMode(BTN_MODE, INPUT_PULLUP);  // GPIO12
  pinMode(BTN_SPEED, INPUT_PULLUP); // GPIO13
  pinMode(BTN_SWING, INPUT);        // GPIO34 — ext 10kΩ to 3.3V required
  pinMode(BTN_MIST, INPUT);         // GPIO35 — ext 10kΩ to 3.3V required

  pinMode(IN1, OUTPUT);
  digitalWrite(IN1, LOW);
  pinMode(IN2, OUTPUT);
  digitalWrite(IN2, LOW);
  pinMode(STEP_PIN, OUTPUT);
  digitalWrite(STEP_PIN, LOW);
  pinMode(DIR_PIN, OUTPUT);
  digitalWrite(DIR_PIN, LOW);

  // Relays — active LOW, all OFF at boot
  pinMode(RELAY1, OUTPUT);
  digitalWrite(RELAY1, HIGH);
  pinMode(RELAY2, OUTPUT);
  digitalWrite(RELAY2, HIGH);
  pinMode(RELAY4, OUTPUT);
  digitalWrite(RELAY4, HIGH);

  // Boot test — blinks light relay once to confirm GPIO19 wiring
  delay(500);
  digitalWrite(RELAY4, LOW); // ON
  delay(500);
  digitalWrite(RELAY4, HIGH); // OFF

  // LEDC PWM for fan (Core v3 style — matches Doc4)
  ledcAttach(ENA, 5000, 8);
  ledcWrite(ENA, 0);

  dht.begin();

  tft.initR(INITR_BLACKTAB);
  tft.setRotation(1);

  // Re-claim GPIO19 after TFT init (SPI steals it as MISO)
  pinMode(RELAY4, OUTPUT);
  digitalWrite(RELAY4, HIGH);

  bootTime = millis();
  Serial.println("==============================");
  Serial.println("  SMART FAN v4.2");
  Serial.println("  PIR: L=GPIO14 C=GPIO27 R=GPIO26");
  Serial.println("  BTN: MODE=12 SPEED=13 SWING=34 MIST=35");
  Serial.println("  R1=GPIO21  R2=GPIO22  R4(Light)=GPIO19");
  Serial.println("  Cmds: A M + - SN SF MI MF LN LF TM OM NM PM ST");
  Serial.println("==============================");

  showCalibration();
  firstDraw = true;
  setupCloud();
}

// ============================================================
//  LOOP
// ============================================================
void loop() {
  handleButtons();
  handleSerial();

  int pirL = digitalRead(PIR_LEFT);
  int pirC = digitalRead(PIR_CENTER);
  int pirR = digitalRead(PIR_RIGHT);
  bool human = pirL || pirC || pirR;

  // DHT22 read — max 0.5Hz, so guard with 2s timer
  static float loopTemp = 25.0;
  static int loopSpeed = 0;
  static unsigned long lastDhtRead = 0;
  if (millis() - lastDhtRead > 2000) {
    float t = dht.readTemperature();
    if (!isnan(t))
      loopTemp = t;
    lastDhtRead = millis();
  }

  // ── AUTO MODE ──────────────────────────────────────────────────────────
  if (isAutoMode) {
    // FIX: reset timer on EVERY detection so fan stays on while human is
    // present
    if (human) {
      runStartTime = millis();
      if (!fanRunning) {
        fanRunning = true;
        Serial.println("[AUTO] Human detected — fan ON");
      }
    }

    if (fanRunning) {
      // CAL_TEMP_SPEED — temperature thresholds for AUTO fan speed.
      // <25°C → LOW(160)   25–30°C → MED(200)   ≥30°C → HI(255)
      // Change the numbers to match your comfort range.
      loopSpeed = (loopTemp < 25) ? 160 : (loopTemp < 30) ? 200 : 255;
      digitalWrite(IN1, HIGH);
      digitalWrite(IN2, LOW);
      ledcWrite(ENA, loopSpeed);
      controlMistBySpeed(loopSpeed);

      // PIR-based swing direction in AUTO
      if (pirL && pirR) {
        if (swingType != 1) {
          swingType = 1;
          swingMode = true;
          modeState = "SWING";
          firstDraw = true;
        }
      } else if (pirL) {
        if (swingType != 2) {
          swingType = 2;
          swingMode = true;
          modeState = "L-C";
          firstDraw = true;
        }
      } else if (pirR) {
        if (swingType != 3) {
          swingType = 3;
          swingMode = true;
          modeState = "R-C";
          firstDraw = true;
        }
      } else {
        if (swingMode) {
          swingType = 0;
          swingMode = false;
          moveToCenter();
          modeState = "CENTER";
          firstDraw = true;
        }
      }

      // Execute swing step
      if (swingType > 0 && millis() - lastSwingTime > swingInterval) {
        switch (swingType) {
        case 1:
          if (!swingDirection)
            moveLeft();
          else
            moveRight();
          break;
        case 2:
          if (!swingDirection)
            moveLeft();
          else
            moveToCenter();
          break;
        case 3:
          if (!swingDirection)
            moveRight();
          else
            moveToCenter();
          break;
        }
        swingDirection = !swingDirection;
        lastSwingTime = millis();
      }

      // CAL_IDLE_TIMEOUT — stop fan after this many ms with no human detected
      if (!human && (millis() - runStartTime >= RUN_DURATION)) {
        swingType = 0;
        swingMode = false;
        moveToCenter();
        modeState = "CENTER";
        controlMistBySpeed(160); // turns mist OFF
        digitalWrite(IN1, LOW);
        digitalWrite(IN2, LOW);
        ledcWrite(ENA, 0);
        fanRunning = false;
        loopSpeed = 0;
        Serial.println("[AUTO] Idle timeout — fan OFF");
      }
    } else {
      loopSpeed = 0;
      digitalWrite(IN1, LOW);
      digitalWrite(IN2, LOW);
      ledcWrite(ENA, 0);
      controlMistBySpeed(0);
    }

    // ── MANUAL / TRAVEL / OFFICE / NIGHT MODES ────────────────────────────
  } else {
    loopSpeed = fanRunning ? manualSpeeds[manualSpeedLevel] : 0;
    if (fanRunning) {
      digitalWrite(IN1, HIGH);
      digitalWrite(IN2, LOW);
      ledcWrite(ENA, loopSpeed);
    } else {
      digitalWrite(IN1, LOW);
      digitalWrite(IN2, LOW);
      ledcWrite(ENA, 0);
    }

    // Execute swing step (type set by button or cloud command)
    if (swingMode && swingType > 0 &&
        millis() - lastSwingTime > swingInterval) {
      switch (swingType) {
      case 1:
        if (!swingDirection)
          moveLeft();
        else
          moveRight();
        break; // L <-> R
      case 2:
        if (!swingDirection)
          moveLeft();
        else
          moveToCenter();
        break; // L <-> C
      case 3:
        if (!swingDirection)
          moveRight();
        else
          moveToCenter();
        break; // R <-> C
      }
      swingDirection = !swingDirection;
      lastSwingTime = millis();
    }
  }

  // ── Update display ─────────────────────────────────────────────────────
  updateDisplay(loopTemp, loopSpeed, pirL, pirC, pirR);

  // ── Cloud sync ─────────────────────────────────────────────────────────
  pushStatus(loopTemp, loopSpeed, pirL, pirC, pirR);
  pollCloudCommand();

  delay(50);
}
