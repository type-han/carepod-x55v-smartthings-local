# 5. 분석 과정 (다른 모델에 응용할 때)

X55V를 어떻게 분석했는지 요약합니다. 다른 CAREPOD 모델이나 비슷한 가습기를 로컬화할 때 참고하세요.

## 5-1. LAN 직접 제어가 되는지 확인

1. 공유기 DHCP 목록에서 가습기 MAC을 찾습니다. X55V의 WiFi 모듈은 **Lierda** (MAC 앞자리 `A0:C6:A5`)였습니다.
2. 가습기 IP에 TCP 포트 스캔 → **열린 포트 없음.**
3. 휴대폰에서 [PCAPdroid](https://github.com/emanuele-f/PCAPdroid)로 CAREPOD 앱만 캡처 → 앱과 가습기 사이 **LAN 통신 없음**, 모두 클라우드 경유.

→ 앱이 LAN으로 직접 제어하는 경로는 없습니다. 대신 클라우드와의 연결을 가로채야 합니다.

## 5-2. 가습기 쪽 트래픽 캡처

가습기 트래픽은 일반 PC에서는 보이지 않으므로, 트래픽이 지나가는 지점을 만들었습니다.

- 리눅스(Proxmox) 무선랜으로 AP를 띄우고 가습기를 거기에 다시 등록 ([01_LOCAL_BROKER.md](01_LOCAL_BROKER.md) 방법 A의 hostapd 설정)
- AP 서버에서 캡처:
  ```bash
  tcpdump -i wlp2s0 -U -w carepod.pcap ether host <가습기 MAC>
  ```
- 앱으로 전원·단계 등을 조작하면서 1–2분 캡처

분석 (Python 3.7+, 외부 패키지 없음):
```bash
python tools/analyze_pcap.py carepod.pcap --target <가습기 IP>     # 흐름별 목적지, DNS 이름, TLS SNI
python tools/mqtt_decode.py carepod.pcap                          # 평문 MQTT 패킷 디코드 (비밀번호는 가림)
```

알게 된 것:
- 접속 대상은 DNS 이름 `device-api.healthnbio.com`, **1883 평문 MQTT**. 443은 접속 전에 한 번만.
- 명령 토픽 `v1/HNB/<ID>/cmd`와 payload 형식 ([03_PROTOCOL.md](03_PROTOCOL.md))

## 5-3. 443 차단 테스트

AP 서버에서 가습기 → 클라우드 443만 임시로 막고(nftables) WiFi 재접속과 전원 재부팅을 시험했습니다.
두 경우 모두 MQTT까지 정상으로 접속했습니다 → **443은 WiFi 등록 때만 필요**하고, 1883만 돌리면 된다는 결론.

## 5-4. 로컬 명령 검증

브로커로 돌린 뒤 `mosquitto_pub`으로 명령을 보내며 펌웨어 특성을 확인했습니다:
키 순서 의존, 같은 msgId 무시, ack 밀림, 위험한 값 ([04_SAFETY.md](04_SAFETY.md)).

## 다른 모델에서 확인할 것

- 1883이 **평문**인지 (TLS면 이 방법은 쓸 수 없음)
- 토픽 구조가 `v1/HNB/<ID>/…`로 같은지, `state` payload 필드
- 위험한 값이 있는지 — **새 path나 값은 한 번에 하나씩, 앱에서 쓰는 값만** 시험하세요

결과를 [이슈](https://github.com/type-han/carepod-x55v-smartthings-local/issues/new/choose)로 공유해 주시면 지원 모델을 늘리는 데 도움이 됩니다. pcap 원본은 올리지 마세요 (비밀번호 포함).
