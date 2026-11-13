"""pcap / pcapng 흐름 요약기 (표준 라이브러리만 사용, Python 3.7+).

출력: 흐름별 목적지·포트·패킷/바이트 수·시간 구간, DNS로 얻은 이름, TLS SNI, HTTP Host,
평문 흐름의 첫 페이로드 미리보기. LAN 목적지와 --target으로 준 기기(가습기 IP)는 따로 표시한다.

사용: python analyze_pcap.py capture.pcap [--target <가습기 IP>]
"""
import ipaddress
import socket
import struct
import sys
from collections import OrderedDict

TARGET = None  # --target <ip>


# ---------- 파일 읽기 ----------

def read_packets(path):
    """(timestamp, linktype, bytes) 를 순서대로 yield."""
    with open(path, "rb") as f:
        data = f.read()
    magic = data[:4]
    if magic == b"\x0a\x0d\x0d\x0a":
        yield from _read_pcapng(data)
        return
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        e = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        e = ">"
    else:
        raise SystemExit("pcap/pcapng 파일이 아님 (magic=%s)" % magic.hex())
    nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
    linktype = struct.unpack(e + "I", data[20:24])[0]
    off = 24
    while off + 16 <= len(data):
        sec, frac, incl, _orig = struct.unpack(e + "IIII", data[off:off + 16])
        off += 16
        pkt = data[off:off + incl]
        off += incl
        yield sec + frac / (1e9 if nano else 1e6), linktype, pkt


def _read_pcapng(data):
    off = 0
    e = "<"
    ifaces = []
    while off + 12 <= len(data):
        btype = struct.unpack(e + "I", data[off:off + 4])[0]
        if btype == 0x0A0D0D0A:
            bom = data[off + 8:off + 12]
            e = "<" if bom == b"\x4d\x3c\x2b\x1a" else ">"
            ifaces = []
        blen = struct.unpack(e + "I", data[off + 4:off + 8])[0]
        if blen < 12:
            break
        body = data[off + 8:off + blen - 4]
        if btype == 1:  # IDB
            ifaces.append(struct.unpack(e + "H", body[:2])[0])
        elif btype == 6:  # EPB
            iface, th, tl, cap, _orig = struct.unpack(e + "IIIII", body[:20])
            ts = ((th << 32) | tl) / 1e6
            yield ts, ifaces[iface] if iface < len(ifaces) else 1, body[20:20 + cap]
        elif btype == 3:  # SPB
            yield 0.0, ifaces[0] if ifaces else 1, body[4:]
        off += blen


# ---------- 계층 파싱 ----------

def l3(linktype, pkt):
    """IP 패킷 bytes 반환 (없으면 None)."""
    if linktype == 1:  # Ethernet
        etype = struct.unpack(">H", pkt[12:14])[0]
        off = 14
        while etype in (0x8100, 0x88A8):
            etype = struct.unpack(">H", pkt[off + 2:off + 4])[0]
            off += 4
        return pkt[off:] if etype in (0x0800, 0x86DD) else None
    if linktype == 113:  # Linux SLL
        return pkt[16:]
    if linktype == 276:  # Linux SLL2
        return pkt[20:]
    if linktype in (101, 228, 229, 12, 14):  # RAW
        return pkt
    if linktype == 0:  # BSD loopback
        return pkt[4:]
    return None


def parse_ip(ip):
    if not ip:
        return None
    v = ip[0] >> 4
    if v == 4:
        ihl = (ip[0] & 0x0F) * 4
        total = struct.unpack(">H", ip[2:4])[0]
        proto = ip[9]
        src, dst = socket.inet_ntoa(ip[12:16]), socket.inet_ntoa(ip[16:20])
        return proto, src, dst, ip[ihl:total if total else None]
    if v == 6:
        proto = ip[6]
        src = str(ipaddress.IPv6Address(ip[8:24]))
        dst = str(ipaddress.IPv6Address(ip[24:40]))
        return proto, src, dst, ip[40:]
    return None


def parse_l4(proto, seg):
    if proto == 6 and len(seg) >= 20:
        sp, dp = struct.unpack(">HH", seg[:4])
        doff = (seg[12] >> 4) * 4
        flags = seg[13]
        return "TCP", sp, dp, seg[doff:], flags
    if proto == 17 and len(seg) >= 8:
        sp, dp = struct.unpack(">HH", seg[:4])
        return "UDP", sp, dp, seg[8:], 0
    return None


# ---------- 응용 계층 힌트 ----------

def _dns_name(msg, off, depth=0):
    labels = []
    while off < len(msg) and depth < 20:
        n = msg[off]
        if n == 0:
            return ".".join(labels), off + 1
        if n & 0xC0 == 0xC0:
            ptr = struct.unpack(">H", msg[off:off + 2])[0] & 0x3FFF
            name, _ = _dns_name(msg, ptr, depth + 1)
            labels.append(name)
            return ".".join(labels), off + 2
        labels.append(msg[off + 1:off + 1 + n].decode(errors="replace"))
        off += 1 + n
    return ".".join(labels), off


def parse_dns(msg, names, queries):
    try:
        _id, flags, qd, an, _ns, _ar = struct.unpack(">HHHHHH", msg[:12])
        off = 12
        for _ in range(qd):
            q, off = _dns_name(msg, off)
            off += 4
            queries.add(q)
        if not flags & 0x8000:
            return
        for _ in range(an):
            name, off = _dns_name(msg, off)
            rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
            off += 10
            rdata = msg[off:off + rdlen]
            off += rdlen
            if rtype == 1 and rdlen == 4:
                names.setdefault(socket.inet_ntoa(rdata), name)
            elif rtype == 28 and rdlen == 16:
                names.setdefault(str(ipaddress.IPv6Address(rdata)), name)
    except Exception:
        pass


def tls_sni(p):
    """TLS ClientHello에서 SNI 추출."""
    try:
        if len(p) < 43 or p[0] != 0x16 or p[5] != 0x01:
            return None
        off = 9 + 2 + 32  # record hdr(5) + hs hdr(4) + version + random
        off += 1 + p[off]  # session id
        off += 2 + struct.unpack(">H", p[off:off + 2])[0]  # cipher suites
        off += 1 + p[off]  # compression
        end = off + 2 + struct.unpack(">H", p[off:off + 2])[0]
        off += 2
        while off + 4 <= end:
            et, el = struct.unpack(">HH", p[off:off + 4])
            if et == 0:
                nl = struct.unpack(">H", p[off + 7:off + 9])[0]
                return p[off + 9:off + 9 + nl].decode(errors="replace")
            off += 4 + el
    except Exception:
        pass
    return None


def http_host(p):
    if p[:4] in (b"GET ", b"POST", b"PUT ", b"HEAD") or p[:7] in (b"DELETE ", b"OPTIONS"):
        for line in p.split(b"\r\n")[:30]:
            if line.lower().startswith(b"host:"):
                return line[5:].strip().decode(errors="replace")
        return "(http, no host)"
    return None


def preview(p, n=48):
    s = "".join(chr(c) if 32 <= c < 127 else "." for c in p[:n])
    return "%s | %s" % (p[:n].hex(), s)


def is_lan(ip):
    try:
        a = ipaddress.ip_address(ip)
        return a.is_private or a.is_link_local or a.is_multicast
    except ValueError:
        return False


# ---------- 메인 ----------

def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    args = sys.argv[1:]
    global TARGET
    if "--target" in args:
        i = args.index("--target")
        TARGET = args[i + 1]
        del args[i:i + 2]
    if not args:
        raise SystemExit(__doc__)

    flows = OrderedDict()
    names, queries = {}, set()
    t0 = None
    npkt = 0
    for ts, lt, pkt in read_packets(args[0]):
        ip = parse_ip(l3(lt, pkt))
        if not ip:
            continue
        proto, src, dst, seg = ip
        l4 = parse_l4(proto, seg)
        if not l4:
            continue
        kind, sp, dp, payload, flags = l4
        npkt += 1
        t0 = ts if t0 is None else t0
        rel = ts - t0

        if kind == "UDP" and 53 in (sp, dp):
            parse_dns(payload, names, queries)

        fwd = (kind, src, sp, dst, dp)
        rev = (kind, dst, dp, src, sp)
        if rev in flows:
            key, direction = rev, "down"
        else:
            key, direction = fwd, "up"
            if fwd not in flows:
                flows[fwd] = dict(first=rel, last=rel, pk=[0, 0], by=[0, 0], hint=None,
                                  prev_up=None, prev_down=None, syn=bool(flags & 0x02))
        fl = flows[key]
        fl["last"] = rel
        idx = 0 if direction == "up" else 1
        fl["pk"][idx] += 1
        fl["by"][idx] += len(payload)
        if payload:
            if fl["hint"] is None:
                fl["hint"] = (tls_sni(payload) and "SNI=" + tls_sni(payload)) or \
                             (http_host(payload) and "HTTP Host=" + http_host(payload))
            pk = "prev_" + direction
            if fl[pk] is None:
                fl[pk] = payload

    print("packets=%d flows=%d\n" % (npkt, len(flows)))

    def row(k, fl):
        kind, s, sp, d, dp = k
        name = names.get(d, "")
        return "%-3s %15s:%-5d -> %-39s %-30s %6.1f~%6.1fs  up %4dp/%7dB  down %4dp/%7dB  %s" % (
            kind, s, sp, "%s:%d" % (d, dp), name[:30], fl["first"], fl["last"],
            fl["pk"][0], fl["by"][0], fl["pk"][1], fl["by"][1], fl["hint"] or "")

    tgt = [(k, f) for k, f in flows.items() if TARGET and TARGET in (k[1], k[3])]
    lan = [(k, f) for k, f in flows.items() if (k, f) not in tgt and is_lan(k[3]) and k[4] != 53]
    wan = [(k, f) for k, f in flows.items() if not is_lan(k[3])]

    if TARGET:
        print("=== ★ 가습기(%s)와 직접 통신: %d개 ===" % (TARGET, len(tgt)))
    for k, f in tgt:
        print(row(k, f))
        for d in ("up", "down"):
            if f["prev_" + d]:
                print("      first %-4s: %s" % (d, preview(f["prev_" + d])))
    print("\n=== 기타 LAN 목적지 (DNS 제외) ===")
    for k, f in lan:
        print(row(k, f))
    print("\n=== 인터넷 목적지 ===")
    for k, f in sorted(wan, key=lambda kf: -sum(kf[1]["by"])):
        print(row(k, f))
        if not (f["hint"] or "").startswith("SNI") and f["prev_up"] and f["prev_up"][:1] != b"\x16":
            print("      first up  : %s" % preview(f["prev_up"]))
    print("\n=== DNS 질의 ===")
    for q in sorted(queries):
        print("  ", q)


if __name__ == "__main__":
    main()
