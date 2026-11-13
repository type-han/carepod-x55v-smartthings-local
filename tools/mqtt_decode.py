"""pcap에서 MQTT(평문) TCP 스트림을 재조립해 패킷 단위로 디코드한다.

사용: python mqtt_decode.py capture.pcap [--port 1883] [--show-secret]
비밀번호는 기본으로 가린다.
"""
import struct
import sys
from collections import OrderedDict

from analyze_pcap import read_packets, l3, parse_ip, parse_l4

TYPES = {1: "CONNECT", 2: "CONNACK", 3: "PUBLISH", 4: "PUBACK", 5: "PUBREC", 6: "PUBREL",
         7: "PUBCOMP", 8: "SUBSCRIBE", 9: "SUBACK", 10: "UNSUBSCRIBE", 11: "UNSUBACK",
         12: "PINGREQ", 13: "PINGRESP", 14: "DISCONNECT"}


def mstr(b, off):
    n = struct.unpack(">H", b[off:off + 2])[0]
    return b[off + 2:off + 2 + n], off + 2 + n


def show(b):
    try:
        s = b.decode("utf-8")
        if all(c.isprintable() or c in "\r\n\t" for c in s):
            return s
    except UnicodeDecodeError:
        pass
    return "hex:" + b.hex()


def decode_stream(buf, show_secret):
    out = []
    off = 0
    while off + 2 <= len(buf):
        h = buf[off]
        mult, rl, i = 1, 0, off + 1
        while True:
            if i >= len(buf):
                return out, off
            d = buf[i]
            rl += (d & 0x7F) * mult
            mult *= 128
            i += 1
            if not d & 0x80:
                break
        body = buf[i:i + rl]
        if len(body) < rl:
            return out, off
        off = i + rl
        t = h >> 4
        name = TYPES.get(t, "T%d" % t)
        info = ""
        try:
            if t == 1:
                proto, p = mstr(body, 0)
                lvl, flags, ka = body[p], body[p + 1], struct.unpack(">H", body[p + 2:p + 4])[0]
                p += 4
                cid, p = mstr(body, p)
                parts = ["proto=%s lvl=%d keepalive=%d client_id=%s" % (proto.decode(), lvl, ka, show(cid))]
                if flags & 0x04:
                    wt, p = mstr(body, p)
                    wm, p = mstr(body, p)
                    parts.append("will=%s:%s" % (show(wt), show(wm)))
                if flags & 0x80:
                    u, p = mstr(body, p)
                    parts.append("user=%s" % show(u))
                if flags & 0x40:
                    pw, p = mstr(body, p)
                    parts.append("pass=%s" % (show(pw) if show_secret else "<%d bytes, hidden>" % len(pw)))
                info = " ".join(parts)
            elif t == 3:
                qos = (h >> 1) & 3
                topic, p = mstr(body, 0)
                if qos:
                    p += 2
                info = "qos=%d retain=%d topic=%s\n        payload=%s" % (qos, h & 1, show(topic), show(body[p:]))
            elif t in (8, 10):
                p = 2
                topics = []
                while p < len(body):
                    tp, p = mstr(body, p)
                    if t == 8:
                        p += 1
                    topics.append(show(tp))
                info = "topics=%s" % topics
            elif t == 2:
                info = "rc=%d" % body[1]
        except Exception as e:
            info = "decode err %s raw=%s" % (e, body[:64].hex())
        out.append((name, info))
    return out, off


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    args = sys.argv[1:]
    port = 1883
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    show_secret = "--show-secret" in args
    path = args[0]

    # 흐름별 방향별로 (시간, payload) 이벤트를 모은다
    flows = OrderedDict()
    for ts, lt, pkt in read_packets(path):
        ip = parse_ip(l3(lt, pkt))
        if not ip:
            continue
        l4 = parse_l4(ip[0], ip[3])
        if not l4 or l4[0] != "TCP" or port not in (l4[1], l4[2]):
            continue
        _, sp, dp, payload, _ = l4
        if not payload:
            continue
        if dp == port:
            key, d = (ip[1], sp, ip[2], dp), "C->S"
        else:
            key, d = (ip[2], dp, ip[1], sp), "S->C"
        flows.setdefault(key, {"C->S": [], "S->C": []})[d].append((ts, payload))

    for key, dirs in flows.items():
        print("##### flow %s:%d -> %s:%d" % key)
        events = []
        for d, chunks in dirs.items():
            buf = b""
            for ts, c in chunks:
                buf += c
                pkts, used = decode_stream(buf, show_secret)
                buf = buf[used:]
                events.extend((ts, d, n, i) for n, i in pkts)
        events.sort(key=lambda e: e[0])
        t0 = min(e[0] for e in events) if events else 0
        for ts, d, name, info in events:
            if name in ("PINGREQ", "PINGRESP"):
                continue
            print("[%s] %s %-10s %s" % (d, "%7.1f" % (ts - t0), name, info))


if __name__ == "__main__":
    main()
