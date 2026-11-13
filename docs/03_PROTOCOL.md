# 3. CAREPOD X55V 통신 프로토콜

가습기 쪽 트래픽을 직접 캡처해서 확인한 내용입니다 (`fw_mcu 1.0.4`, `fw_wifi 0.0.1`).
다른 펌웨어에서는 다를 수 있습니다. 아래에서 `<ID>`는 deviceId(가습기 MAC, 대문자, 구분자 없음)입니다.

## 전체 구조

```
CAREPOD 앱 ──HTTPS──▶ 제조사 클라우드                      ← 앱의 명령. 앱과 가습기 사이 LAN 직접 통신은 없음
가습기 ──HTTPS :443──▶ device-api.healthnbio.com          ← WiFi를 처음 등록할 때만
가습기 ◀─MQTT 3.1.1 평문 :1883─▶ device-api.healthnbio.com ← 상태 발행 + 명령 수신 (항상)
```

## 접속 순서

| 순서 | 동작 |
|---|---|
| 1 | DHCP |
| 2 | (전원을 켰을 때만) DNS `time.google.com` → NTP, DNS `device-api.healthnbio.com` |
| 3 | (처음 등록할 때만) HTTPS `device-api.healthnbio.com:443` |
| 4 | MQTT `device-api.healthnbio.com:1883` 평문 접속, 이후 계속 유지 |

- WiFi만 다시 붙을 때는 DNS를 다시 조회하지 않고 예전 IP를 씁니다.
- 443을 막아도 평소 부팅·재접속은 MQTT까지 정상으로 갑니다 (443 차단 테스트로 확인).
- 브로커가 재시작되면 가습기는 약 1분 뒤 다시 접속합니다.

## CONNECT

- MQTT 3.1.1 (level 4), keepalive 120, clean session
- client_id = username = `<ID>`, 비밀번호 64바이트 (로컬 브로커는 검사하지 않음)
- Will: `v1/HNB/<ID>/presence` (retain, qos1) `{"status":"offline","reason":"unexpected"}`

접속 직후:
1. SUBSCRIBE `v1/HNB/<ID>/cmd`, `cmd/ota`, `cmd/cert`
2. PUBLISH `capability` (retain, 처음 등록할 때만): `{"model":"x55v","fw_mcu":"1.0.4","features":["mist","sleep","heat","sterilize","timer"]}`
3. PUBLISH `presence` (retain): `{"status":"online","reason":null}`
4. PUBLISH `state` (retain)
5. 클라우드가 `cmd`로 `restore`를 보냄 → **로컬에서는 드라이버가 대신 보냄**

> 다른 클라이언트가 `<ID>`와 같은 client_id로 접속하면 브로커가 가습기 연결을 끊습니다. 드라이버는 `st-carepod-…`를 씁니다.

## 토픽 (`v1/HNB/<ID>/…`)

| 토픽 | 방향 | 내용 |
|---|---|---|
| `state` | 가습기 → (retain) | 전원, 분무, 히터, 살균, 팬, 배수, 타이머, 취침, 잠금, 오류/경고 |
| `telemetry` | 가습기 → | 온도, 습도, 수위, 히터 온도 (약 15초 주기, 접속 후 약 50초부터) |
| `presence` | 가습기 → (retain) | online / offline |
| `capability` | 가습기 → (retain) | 모델, 펌웨어, 기능 목록 |
| `evt/ota` | 가습기 → | 펌웨어 업데이트 이벤트 |
| `cmd` | → 가습기 (qos1) | 명령 |
| `cmd/ack` | 가습기 → | 명령 처리 결과 |
| `cmd/ota`, `cmd/cert` | → 가습기 | 구독만 확인. 메시지는 관찰하지 못함 |

### state 예시

```json
{"ts":1794491663,"msgId":"<uuid>","deviceId":"<ID>","fw_wifi":"0.0.1","type":"state",
 "payload":{"model":"x55v","fw_mcu":"1.0.4","power":1,
  "wifi":{"connected":1,"rssi":-44,"reset":0},
  "mist":{"step":5,"target_humidity":50},
  "heat":{"state":1,"target_x10":490,"current_x10":490},
  "sterilize":{"state":0,"remain":0},
  "fan":{"step":5,"state":1},
  "drain":{"active":0,"remain":0},
  "timer":{"active":0,"remain":0},
  "sleep":{"active":0},
  "child_lock":{"active":0},
  "errors":"","warning":"0","ota_active":0}}
```

### telemetry 예시

```json
{"type":"telemetry","payload":{"temp_x10":287,"humidity":47,"water_level":3,"heater_temp_x10":489,"vibrator_mv":355}}
```

- 온도는 ×10 (`287` = 28.7℃), 습도는 %, `water_level`은 **0–3** (3이 가득).

## 명령 (`v1/HNB/<ID>/cmd`, qos1)

```json
{"ts":1794569671,"msgId":"<uuid4>","deviceId":"<ID>","fw_wifi":"0.0.1","type":"cmd",
 "payload":{"op":"set","path":"power","value":0}}
```

가습기 응답: PUBACK → `cmd/ack` `{"msgId":"<같은 uuid>","type":"ack","payload":{"status":"ok"}}` → 바뀐 `state` (0.1초 이내)

### 펌웨어 특성 (반드시 지킬 것)

- **키 순서를 지켜야 합니다**: `ts, msgId, deviceId, fw_wifi, type, payload{op, path, value}`.
  순서가 다르면 ack도 상태 변화도 없이 무시됩니다. 그래서 드라이버는 JSON을 문자열로 직접 조립합니다 (`carepod.make_cmd`).
- 공백은 있어도 없어도 됩니다.
- **같은 msgId는 다시 처리하지 않습니다.** 명령마다 새 uuid를 쓰세요.
- **ack가 하나씩 밀릴 수 있습니다.** 처리하지 못한 명령을 받은 뒤에는 다음 명령에 대해 이전 msgId로 ack를 보냅니다.
  → 명령 성공 여부는 ack가 아니라 **state 변화**로 판단하세요.
- 명령을 1–2초 간격으로 연달아 보내면 하나가 무시되는 경우가 있습니다.
- `fw_wifi`는 가습기가 보내는 값과 같게 `"0.0.1"`로 보냅니다. 다른 펌웨어에서는 이 값을 맞춰야 할 수 있습니다.

### path / value

| path | value | 메모 |
|---|---|---|
| `power` | 0 / 1 | 0이면 `mist.step` 0, `heat.state` 0 |
| `mist.step` | **1, 2, 3, 5만** | 1–3 = 수동 단계, 5 = 자동. `fan.step`도 같이 바뀜. **0과 4는 보내지 말 것** ([04_SAFETY.md](04_SAFETY.md)) |
| `mist.target_humidity` | **40, 45, 50, 55, 60만** | 다른 값은 고장을 일으킴 |
| `heat.state` | 0 / 1 | |
| `child_lock.active` | 0 / 1 | |
| `sleep.active` | 0 / 1 | 1이면 기기가 `mist.step`을 4로, `heat.state`를 0으로 바꿈. 해제하면 step 5 |
| `sterilize.state` | 0 / 1 | 1이면 `heat.state`도 1 |
| `timer` | 초: 14400, 21600, 28800, 0(해제) | `timer.active` 1, `remain` = 값. 드라이버에는 넣지 않음 (자동화로 대신) |
| `restore` | `{"country":"KR","utc_offset_min":540,"now":<epoch>}` | 접속 직후. 시각·지역 설정으로 보임 |

### 오류 / 경고

- `state.errors`는 정상일 때 `""`, `state.warning`은 정상일 때 `"0"`입니다.
- 코드별 의미는 아직 모릅니다. 드라이버는 `E:<errors>`, `W:<warning>` 형태로 그대로 보여 줍니다.
- 경고나 오류가 뜨면 **코드와 그때 기기 상황**(물 부족, 물통 분리 등)을 [제보](https://github.com/type-han/carepod-x55v-smartthings-local/issues/new/choose)해 주세요.

## SmartThings 매핑 (드라이버)

| 가습기 | 컴포넌트 | capability |
|---|---|---|
| `power` | main | `switch` |
| `telemetry.humidity` | main | `relativeHumidityMeasurement` |
| `telemetry.temp_x10` | main | `temperatureMeasurement` |
| `telemetry.water_level` | main | `waterLevel` (커스텀, 0–3) |
| `errors`, `warning` | main | `deviceAlert` (커스텀, normal/warning/error + 코드) |
| `mist.step` | mist | `mode`: 1단계 / 2단계 / 3단계 / 자동 (+ 읽기 전용 "취침") |
| `mist.target_humidity` | humidityTarget | `mode`: 40% … 60% |
| `heat.state` | heat | `switch` |
| `sterilize.state` | sterilize | `switch` |
| `sleep.active` | sleep | `switch` |
| `child_lock.active` | childLock | `switch` |

- 전원이 꺼져 있을 때 분무량을 바꾸면 드라이버가 먼저 켜고 1.5초 뒤에 단계를 보냅니다.
- presence가 online이 되면 `restore`를 보냅니다 (30초 안에 다시 보내지 않음).
