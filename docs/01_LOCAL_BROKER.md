# 1. 로컬 브로커와 트래픽 돌리기

## 해야 할 일은 하나

가습기는 켜질 때마다 `device-api.healthnbio.com`의 **tcp/1883(평문 MQTT)** 에 접속합니다.
이 연결이 **LAN의 Mosquitto에 도착하게** 만들면 됩니다.

- 443(HTTPS)은 **WiFi를 처음 등록할 때만** 씁니다. 평소 부팅·재접속에는 1883만 씁니다. 그래서 443은 건드리지 않습니다.
- 가습기는 username(= deviceId)과 비밀번호를 보내지만, 로컬 브로커는 비밀번호를 검사하지 않습니다.
- 가습기가 접속하면 클라우드가 보내던 `restore`(국가, 시간대, 현재 시각) 명령을 **드라이버가 대신 보냅니다.**

---

## 1-1. Mosquitto 설치 (모든 방법 공통)

Debian / Ubuntu / Raspberry Pi OS 기준:

```bash
sudo apt update && sudo apt install -y mosquitto mosquitto-clients
sudo cp broker/carepod.conf /etc/mosquitto/conf.d/carepod.conf
sudo systemctl restart mosquitto && sudo systemctl enable mosquitto
```

- 브로커 IP는 **고정**해 두세요 (공유기 DHCP 예약 등). 드라이버 설정에 이 IP를 넣습니다.
- 다른 기기가 접속하는지 보려면: `mosquitto_sub -h localhost -v -t 'v1/HNB/#'`

## 1-2. 가습기 트래픽 돌리기 (방법 셋 중 하나)

### 방법 A. 리눅스 무선 AP + nftables ✅ 검증됨

무선랜이 있는 리눅스 서버(여기서는 Proxmox 호스트)를 AP로 띄우고, 가습기를 그 AP에 연결합니다.
AP는 LAN 브리지에 붙어 있어서 가습기는 공유기에서 평소처럼 IP를 받습니다. AP에서 **가습기의 외부행 1883 패킷만** 브로커로 보냅니다.

```
가습기 ─WiFi─▶ AP (wlp2s0, 브리지 vmbr0) ──────────────▶ 브로커 (같은 브리지의 컨테이너/VM)
  목적지: 클라우드 IP:1883     ① AP의 nft bridge 규칙:              ② 브로커의 nft nat 규칙:
                                  목적지 MAC만 브로커 MAC으로 바꿈       redirect → mosquitto :1883
                               응답은 conntrack이 클라우드 IP로 되돌려서 보내므로 가습기는 눈치채지 못함
```

**준비 조건**
- AP 모드를 지원하는 무선랜: `iw list | sed -n '/Supported interface modes/,/^\s*$/p'`에 `AP`가 있어야 합니다.
- 브로커는 **AP와 같은 리눅스 브리지에 붙은 별도 컨테이너/VM**이어야 합니다 (MAC을 바꿔서 보내는 방식이라).
- 이 구성은 AP 서버에 의존합니다. **AP 서버가 꺼지면 가습기는 WiFi와 제어를 모두 잃습니다** (본체 버튼은 동작).

**AP 서버에서** ([`examples/proxmox-ap/`](../examples/proxmox-ap/))

```bash
apt install -y hostapd iw
cp carepod-cap.conf.example /etc/hostapd/carepod-cap.conf    # ssid, channel, bridge, wpa_passphrase 수정
chmod 600 /etc/hostapd/carepod-cap.conf
hostapd -dd /etc/hostapd/carepod-cap.conf     # 먼저 포그라운드로 테스트, AP-ENABLED가 나오면 Ctrl+C
mkdir -p /etc/carepod && cp redirect.nft /etc/carepod/redirect.nft    # <HUMIDIFIER_MAC> <BROKER_MAC> <LAN_CIDR> 수정
cp carepod-ap.service carepod-redirect.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now carepod-ap carepod-redirect
```

- SSID는 **기존 WiFi와 다른 이름**으로 하세요. 같은 이름이면 다른 기기들이 이 AP로 넘어옵니다.
- 채널은 공유기와 같은 채널이나 1/6/11 중 하나로. 가습기는 2.4GHz만 씁니다.
- 패키지 기본 `hostapd.service`는 쓰지 않습니다 (위 `carepod-ap.service`가 대신함).
- 가습기 MAC은 공유기 DHCP 목록에서 찾거나, 가습기를 AP에 붙인 뒤 `iw dev wlp2s0 station dump`로 확인합니다.

**브로커(컨테이너)에서**

```bash
apt install -y nftables
cp broker/nftables.conf /etc/nftables.conf    # <LAN_CIDR>, 인터페이스 이름 수정
systemctl enable --now nftables
```

**가습기 연결**: CAREPOD 앱에서 가습기 WiFi를 새 AP로 다시 등록합니다 (이때는 클라우드 443이 필요하며, 리다이렉트는 443을 건드리지 않습니다).

**재부팅 확인**: AP 서버를 재부팅해서 AP, 규칙, 브로커가 모두 자동으로 올라오고 가습기가 1–2분 안에 다시 접속하는지 확인하세요.

### 방법 B. 공유기 DNAT ❓ 미검증

OpenWrt처럼 규칙을 세밀하게 넣을 수 있는 공유기라면 가장 깔끔합니다.
조건: **출발지 = 가습기 IP, 목적지 = LAN 밖, tcp/1883 → 브로커 IP:1883으로 DNAT**.
브로커와 가습기가 같은 LAN에 있으면 응답이 공유기를 거치지 않아 연결이 깨질 수 있으므로, 공유기에서 SNAT(masquerade)도 같이 걸어야 할 수 있습니다.
성공하면 [제보](https://github.com/type-han/carepod-x55v-smartthings-local/issues/new/choose) 부탁드립니다.

### 방법 C. DNS 재지정 ❓ 미검증

Pi-hole / AdGuard Home / 공유기 DNS에서 `device-api.healthnbio.com`을 **브로커 IP**로 응답하게 합니다. 브로커는 1883만 열어 두면 되고 nftables는 필요 없습니다.

주의할 점 (분석 중 확인한 가습기 동작):
- 가습기는 **전원을 껐다 켤 때만 DNS를 다시 조회**합니다. WiFi만 다시 붙을 때는 예전에 받은 IP를 그대로 씁니다 → 설정 후 **가습기 전원을 한 번 껐다 켜세요.**
- 같은 이름을 443(등록)에도 쓰므로, 이 상태에서는 **WiFi 재등록이 실패**합니다. 재등록할 때는 DNS 재지정을 잠시 끄세요.
- 가습기가 공유기 DNS를 쓰므로 공유기의 DNS 서버 설정을 바꿔야 할 수 있습니다.

## 1-3. 연결 확인과 deviceId 찾기

가습기가 브로커에 붙으면 Mosquitto 로그에 이렇게 남습니다:

```
New client connected from 192.168.1.23:xxxxx as A0C6A5XXXXXX (p2, c1, k120, u'A0C6A5XXXXXX').
```

- `as` 뒤의 12자리가 **deviceId**입니다 (가습기 MAC을 대문자로, 구분자 없이 쓴 값).
- 로그 위치: `/var/log/mosquitto/mosquitto.log` 또는 `journalctl -u mosquitto`
- 상태 메시지 보기: `mosquitto_sub -h <브로커IP> -v -t 'v1/HNB/#'` → `presence`(online), `state`, 15초쯤 뒤부터 `telemetry`

## 1-4. 브로커에서 직접 명령 보내 보기 (선택)

```bash
ID=A0C6A5XXXXXX
mosquitto_pub -h <브로커IP> -q 1 -t "v1/HNB/$ID/cmd" -m "{\"ts\":$(date +%s),\"msgId\":\"$(cat /proc/sys/kernel/random/uuid)\",\"deviceId\":\"$ID\",\"fw_wifi\":\"0.0.1\",\"type\":\"cmd\",\"payload\":{\"op\":\"set\",\"path\":\"power\",\"value\":0}}"
```

- **키 순서를 바꾸면 무시됩니다.** msgId는 매번 새로 만들어야 합니다. 자세한 형식은 [03_PROTOCOL.md](03_PROTOCOL.md).
- `value`를 1로 바꾸면 켜집니다. 그 밖의 값을 보내기 전에 [04_SAFETY.md](04_SAFETY.md)를 꼭 읽어 주세요.
