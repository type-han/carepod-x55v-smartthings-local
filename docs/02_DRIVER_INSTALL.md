# 2. Edge 드라이버 설치

먼저 [01_LOCAL_BROKER.md](01_LOCAL_BROKER.md)대로 가습기가 로컬 브로커에 붙어 있어야 합니다.
브로커 IP와 deviceId를 메모해 두세요.

## 2-1. 초대 링크로 설치 (추천)

1. 채널 초대 링크를 엽니다: **준비 중** (그전에는 아래 2-2로 설치하세요)
2. Samsung 계정으로 로그인 → **Accept** → 허브를 선택해 등록(Enroll)
3. **Available Drivers**에서 `CAREPOD X55V Local` → **Install**
4. SmartThings 앱 → **기기 추가** → **주변 기기 검색** (스캔)
   → 1분 안에 **"CAREPOD 가습기"** 가 생깁니다. 처음에는 오프라인입니다.
5. 기기 화면 → 오른쪽 위 **⋮ → 설정**:
   - **MQTT 브로커 IP**: 예) `192.168.1.50`
   - **MQTT 브로커 포트**: `1883` (그대로)
   - **가습기 deviceId**: 예) `A0C6A5123456` (콜론이나 소문자로 넣어도 됩니다)
6. 저장하면 몇 초 안에 온라인이 되고 현재 상태가 표시됩니다.

> 드라이버 업데이트는 같은 채널로 배포되며 허브가 자동으로 받습니다.

## 2-2. 직접 빌드해서 설치 (선택)

코드를 고치거나 내 채널을 쓰고 싶을 때.

1. [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli/releases)를 받습니다 (검증 버전 2.1.3).
2. 로그인과 채널:
   ```bash
   smartthings login
   smartthings edge:channels:create -i driver/channel.json      # 채널 ID를 메모
   smartthings edge:channels:enroll                             # 허브를 채널에 등록 (대화형)
   ```
3. 패키징 + 채널 배정 + 허브 설치를 한 번에:
   ```bash
   smartthings edge:drivers:package driver --channel <채널ID> --hub <허브ID>
   ```
4. 이후 2-1의 4–6단계와 같습니다.

**커스텀 capability**: 수위(`waterLevel`)와 가습기 상태(`deviceAlert`)는 네임스페이스 `fieldforgotten06843`의 커스텀 capability입니다.
다른 계정에서 이 네임스페이스를 그대로 쓸 수 있는지는 **확인하지 못했습니다.** 패키징이 안 되면 내 계정에 같은 정의로 새로 만들고 네임스페이스를 바꿉니다:

```bash
smartthings capabilities:create -i driver/capabilities/waterLevel.json      # 출력된 id의 네임스페이스를 확인
smartthings capabilities:create -i driver/capabilities/deviceAlert.json
# presentation/번역 파일 안의 "id"를 새 네임스페이스로 바꾼 뒤:
smartthings capabilities:presentation:create <새네임스페이스>.waterLevel 1 -i driver/capabilities/waterLevel.presentation.json
smartthings capabilities:translations:create <새네임스페이스>.waterLevel 1 -i driver/capabilities/waterLevel.ko.json
# deviceAlert도 같은 방식
```

그다음 `driver/src/init.lua`의 `NS`와 `driver/profiles/*.yml`의 capability id를 새 네임스페이스로 바꿉니다.

## 2-3. 로그 보기

```bash
smartthings edge:drivers:logcat <드라이버ID> --hub-address <허브IP>
```

정상일 때:

```
broker 192.168.1.50:1883, deviceId A0C6A5123456
mqtt connected to 192.168.1.50:1883 as st-carepod-xxxxxxxx
broker connected; waiting for retained state
sending restore (clock / country) to humidifier
```

| 로그 | 뜻 |
|---|---|
| `broker IP or deviceId is not set` | 기기 설정에 브로커 IP나 deviceId가 비어 있거나 형식이 틀림 (12자리 16진수) |
| `broker disconnected` 반복 | 브로커 IP/포트가 틀렸거나 브로커가 꺼져 있음 |
| 연결은 되는데 상태가 안 옴 | deviceId가 틀렸거나 가습기가 아직 브로커에 붙지 않음 → 브로커 로그 확인 |
| `humidifier alert: warning (W:..)` | 가습기가 경고/오류 코드를 보냄 → [제보](https://github.com/type-han/carepod-x55v-smartthings-local/issues/new/choose) 부탁드립니다 |

## 2-4. 허브 밖에서 테스트 (개발용)

리눅스에 Lua 5.3, luasocket, dkjson, cosock을 설치한 뒤 `driver/`에서:

```bash
lua5.3 test/test_offhub.lua                                   # 단위 테스트 (네트워크 없음)
lua5.3 test/test_offhub.lua --live <브로커IP> <deviceId>        # 실제 가습기: 분무량을 바꿨다가 되돌림
lua5.3 test/test_reconnect.lua <브로커IP> <deviceId>            # 실행 후 15초 안에 mosquitto 재시작
```

> 허브의 cosock은 PC용 cosock 0.2.0과 동작이 다릅니다 (`mqtt.lua` 주석 참고). PC에서 통과해도 허브에서 한 번 더 확인하세요.
