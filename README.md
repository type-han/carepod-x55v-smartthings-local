# CAREPOD X55V → SmartThings 로컬 제어

케어팟(CAREPOD) **X55V** 가습기를 제조사 클라우드 없이, 집 LAN 안에서 **SmartThings Edge 드라이버**로 제어합니다.

> **English summary** — Local (cloud-free) control of the CAREPOD X55V humidifier from SmartThings.
> The humidifier talks to its vendor cloud over **plain-text MQTT (tcp/1883)**. Redirect that traffic to a
> Mosquitto broker on your LAN, then install the Edge driver in this repo: it connects to the same broker and
> exposes power, mist level, target humidity, heater, sterilize, sleep, child lock, humidity, temperature,
> water level and alerts. Unofficial, not affiliated with the manufacturer. Docs are in Korean.

> ⚠️ **비공식 프로젝트입니다.** 제조사(HnB)와 관계가 없고, 제조사가 지원하는 방법이 아닙니다.
> 보증, 기기 고장, 데이터 손실에 대한 책임은 사용자에게 있습니다. [면책](#면책)을 먼저 읽어 주세요.

---

## 어떻게 동작하나

```
                       (원래)  device-api.healthnbio.com:1883  ← 제조사 클라우드 (평문 MQTT)
                                           ▲
                                           │ ✗ 가로챔
  가습기 ──WiFi──▶ AP / 공유기 ─────────────┘
                       │  가습기의 "외부행 tcp/1883"만 LAN 브로커로 돌린다
                       ▼
              LAN의 Mosquitto 브로커  ◀────MQTT────  SmartThings 허브 (이 레포의 Edge 드라이버)
                                                           ▲
                                                     SmartThings 앱 / 자동화
```

- 가습기는 클라우드와 **TLS 없는 MQTT**로 통신합니다. 그래서 그 연결을 LAN의 브로커로 돌리면, 가습기는 클라우드에 붙은 줄 알고 그대로 동작합니다.
- 드라이버는 같은 브로커에 접속해서 상태를 받고 명령을 보냅니다. 인터넷이 끊겨도 동작합니다.
- 가습기는 비밀번호를 보내지만 로컬 브로커는 검사하지 않습니다. 제조사 계정이나 비밀번호는 필요 없습니다.

## 준비물

| 항목 | 설명 |
|---|---|
| CAREPOD X55V | 검증한 펌웨어: `fw_mcu 1.0.4`, `fw_wifi 0.0.1` |
| SmartThings 허브 | Edge 드라이버를 지원하는 허브 (검증: 스마트 홈 허브 V4) |
| 항상 켜져 있는 리눅스 기기 | Mosquitto 브로커용. 라즈베리파이, NAS, Proxmox 컨테이너 등 |
| 가습기 트래픽을 돌릴 방법 | 아래 셋 중 하나. 자세한 내용은 [docs/01_LOCAL_BROKER.md](docs/01_LOCAL_BROKER.md) |

| 방법 | 검증 | 요약 |
|---|---|---|
| 리눅스 무선 AP + nftables | ✅ 검증됨 | 무선랜이 있는 리눅스(Proxmox 등)를 AP로 띄우고 가습기를 거기에 연결 |
| 공유기 DNAT (OpenWrt 등) | ❓ 미검증 | 공유기에서 가습기의 외부행 1883을 브로커로 포트포워딩 |
| DNS 재지정 (Pi-hole 등) | ❓ 미검증 | `device-api.healthnbio.com`을 브로커 IP로. 가습기 재부팅이 필요한 경우가 있음 |

## 빠른 시작

1. **브로커 설치** — 리눅스 기기에 Mosquitto를 설치하고 [`broker/carepod.conf`](broker/carepod.conf)를 넣습니다.
2. **트래픽 돌리기** — [docs/01_LOCAL_BROKER.md](docs/01_LOCAL_BROKER.md)의 방법 하나로 가습기 MQTT를 브로커로 돌립니다.
   브로커 로그에 `New client connected ... as A0C6A5XXXXXX`가 보이면 성공이고, 그 값이 **deviceId**입니다.
3. **드라이버 설치** — 초대 링크로 허브에 드라이버를 설치합니다 → [docs/02_DRIVER_INSTALL.md](docs/02_DRIVER_INSTALL.md)
   - 채널 초대 링크: **준비 중**입니다. 그전에는 [직접 빌드](docs/02_DRIVER_INSTALL.md#2-2-직접-빌드해서-설치-선택)로 설치할 수 있습니다.
4. **기기 추가** — SmartThings 앱 → 기기 추가 → 주변 기기 검색 → "CAREPOD 가습기"가 생기면
   기기 설정에서 **브로커 IP**와 **deviceId**를 입력합니다. 몇 초 안에 온라인이 됩니다.

## SmartThings에서 할 수 있는 것

| 앱 이름 | 기능 | 비고 |
|---|---|---|
| 가습기 | 전원, 현재 습도, 온도, 수위(0–3), 가습기 상태(정상/경고/오류) | 자동화 조건으로 쓸 수 있음 |
| 분무량 | 1단계 / 2단계 / 3단계 / 자동 | 취침 모드일 때는 "취침"으로 표시 (선택 불가) |
| 목표 습도 | 40% / 45% / 50% / 55% / 60% | 다른 값은 기기가 고장 나서 막아 둠 |
| 히터 기능 / 자동 살균 예약 / 취침 모드 / 차일드락 | 켜기·끄기 | |

## 알려진 제한 / 주의

- **로컬로 돌리면 CAREPOD 앱으로는 제어할 수 없습니다.** 클라우드에는 오프라인으로 보입니다.
- 가습기 WiFi를 **처음 등록하거나 다시 등록할 때는 클라우드(443)가 필요**합니다. 리다이렉트는 1883만 돌리므로 등록은 그대로 됩니다.
- 로컬 브로커에서는 **펌웨어 OTA가 오지 않습니다.**
- 제조사가 펌웨어로 TLS를 켜면 이 방법은 막힐 수 있습니다.
- **허브당 가습기 1대**만 지원합니다.
- 경고·오류 코드의 의미를 아직 모릅니다. 코드는 그대로 표시합니다 → 보이면 [제보](https://github.com/type-han/carepod-x55v-smartthings-local/issues/new/choose) 부탁드립니다.
- 명령을 1–2초 간격으로 연달아 보내면 하나가 무시되는 경우가 있습니다 (펌웨어 동작).
- 분무량·목표 습도 카드 제목이 "모드"로 보입니다 (표준 `mode` capability의 한계).
- 브로커는 익명 접속을 허용합니다. **LAN 안의 누구나 가습기에 명령을 보낼 수 있으니** 게스트 WiFi와 분리해 주세요.
- 위험한 값과 되돌리는 방법은 [docs/04_SAFETY.md](docs/04_SAFETY.md)에 있습니다.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/01_LOCAL_BROKER.md](docs/01_LOCAL_BROKER.md) | 브로커 설치, 가습기 트래픽 돌리기, deviceId 찾기 |
| [docs/02_DRIVER_INSTALL.md](docs/02_DRIVER_INSTALL.md) | 초대 링크로 설치 / 직접 빌드, 기기 추가, 로그 보기 |
| [docs/03_PROTOCOL.md](docs/03_PROTOCOL.md) | MQTT 토픽, payload, 명령 형식, 펌웨어 특성 |
| [docs/04_SAFETY.md](docs/04_SAFETY.md) | 보내면 안 되는 값, 클라우드로 되돌리기, 보안 |
| [docs/05_ANALYSIS.md](docs/05_ANALYSIS.md) | 어떻게 분석했는지 (다른 모델에 응용할 때) |

## 레포 구성

```
driver/                Edge 드라이버 (Lua). config.yml, profiles/, src/, capabilities/, test/
broker/                Mosquitto 설정, 브로커 쪽 nftables 템플릿
examples/proxmox-ap/   검증된 참조 구현: 리눅스 무선 AP 브리지 + nftables + systemd
tools/                 pcap 분석 스크립트 (Python 3.7+, 표준 라이브러리만)
docs/                  설명서
```

## 면책

- 이 프로젝트는 개인이 자기 기기를 분석해서 만든 **비공식** 결과물이며, HnB 및 CAREPOD와 관계가 없습니다. "CAREPOD"는 해당 회사의 상표입니다.
- 펌웨어가 예상하지 않은 값을 보내면 기기가 멈출 수 있습니다. 드라이버는 확인된 위험한 값을 막지만, 모든 경우를 보장하지 않습니다.
- 본인 소유 기기와 본인 네트워크에서만 사용하세요.
- MIT 라이선스에 따라 "있는 그대로" 제공되며 어떠한 보증도 없습니다.

## 라이선스

[MIT](LICENSE)
