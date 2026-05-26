/*
 * test_replicate_bpf_filter.c — REQ-NET-12 integration test
 *
 * Valida que las expresiones BPF típicas que un usuario pondría en la
 * sección [filter.replicate] del config:
 *   - se compilan limpio con pcap_compile() (la API que usa config.c)
 *   - matchean los paquetes correctos con pcap_offline_filter() (la
 *     API que usa filters.c → ubond_replicate_filter_match)
 *   - rechazan paquetes que no deben matchear
 *   - syntax inválida produce error de pcap_compile (no crash)
 *
 * No levanta ubond entero (eso requiere root + utun + crypto). Testea
 * la integración con libpcap que es la dependencia externa crítica de
 * REQ-NET-12.
 *
 * Compilación:
 *   clang -I/opt/homebrew/include -L/opt/homebrew/lib -lpcap \
 *         -O2 -Wall -o test_replicate_bpf_filter test_replicate_bpf_filter.c
 *
 * Pasa si: exit 0 + última línea "ALL_TESTS_PASSED".
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>
#include <pcap.h>

/* Construye un paquete IPv4 + UDP en `out` (>=44 bytes). Devuelve longitud total. */
static int build_udp_packet(uint8_t *out, uint16_t src_port, uint16_t dst_port,
                            const char *payload, int payload_len) {
    int ip_hdr_len = 20;
    int udp_hdr_len = 8;
    int total = ip_hdr_len + udp_hdr_len + payload_len;

    /* IP header (mínimo, sin opciones) */
    out[0] = 0x45;                      /* version=4, IHL=5 */
    out[1] = 0x00;                      /* ToS */
    out[2] = (total >> 8) & 0xFF;       /* total length high */
    out[3] = total & 0xFF;              /* total length low */
    out[4] = 0x00; out[5] = 0x01;       /* ID */
    out[6] = 0x40; out[7] = 0x00;       /* flags+frag (DF) */
    out[8] = 64;                        /* TTL */
    out[9] = 17;                        /* Protocol = UDP */
    out[10] = 0x00; out[11] = 0x00;     /* checksum (0 — válido para test) */
    /* Source IP 10.10.10.2 */
    out[12]=10; out[13]=10; out[14]=10; out[15]=2;
    /* Dest IP 1.2.3.4 */
    out[16]=1; out[17]=2; out[18]=3; out[19]=4;

    /* UDP header */
    out[20] = (src_port >> 8) & 0xFF;
    out[21] = src_port & 0xFF;
    out[22] = (dst_port >> 8) & 0xFF;
    out[23] = dst_port & 0xFF;
    int udp_total = udp_hdr_len + payload_len;
    out[24] = (udp_total >> 8) & 0xFF;
    out[25] = udp_total & 0xFF;
    out[26] = 0x00; out[27] = 0x00;     /* UDP checksum (0 — opcional IPv4) */

    if (payload && payload_len > 0)
        memcpy(out + 28, payload, payload_len);

    return total;
}

/* Construye un paquete IPv4 + TCP en `out` (>=40 bytes). */
static int build_tcp_packet(uint8_t *out, uint16_t src_port, uint16_t dst_port) {
    int ip_hdr_len = 20;
    int tcp_hdr_len = 20;
    int total = ip_hdr_len + tcp_hdr_len;

    out[0] = 0x45;
    out[1] = 0x00;
    out[2] = (total >> 8) & 0xFF;
    out[3] = total & 0xFF;
    out[4] = 0x00; out[5] = 0x01;
    out[6] = 0x40; out[7] = 0x00;
    out[8] = 64;
    out[9] = 6;                         /* Protocol = TCP */
    out[10] = 0x00; out[11] = 0x00;
    out[12]=10; out[13]=10; out[14]=10; out[15]=2;
    out[16]=1; out[17]=2; out[18]=3; out[19]=4;

    /* TCP header (mínimo) */
    out[20] = (src_port >> 8) & 0xFF;
    out[21] = src_port & 0xFF;
    out[22] = (dst_port >> 8) & 0xFF;
    out[23] = dst_port & 0xFF;
    /* seq, ack, offset, flags, window, checksum, urgptr */
    memset(out + 24, 0, 16);
    out[32] = 0x50;                     /* data offset = 5 (no opts) */
    out[33] = 0x18;                     /* flags PSH+ACK */

    return total;
}

/*
 * Comprueba el filtro BPF contra un paquete. Devuelve:
 *   1 si matchea, 0 si no, -1 si pcap_compile falla (sintaxis mala)
 *
 * Replica la lógica de ubond_replicate_filter_match: usa
 * pcap_offline_filter contra el header IPv4 raw — exactamente como
 * filters.c hace en runtime.
 */
static int eval_filter(const char *expr, const uint8_t *pkt, int pkt_len) {
    /* DLT_RAW = 12, paquete sin link layer (IP directo). Es lo que
     * usa ubond/mlvpn porque los paquetes que cruzan el túnel son IP raw,
     * no Ethernet. config.c hace pcap_open_dead(DLT_RAW, ...). */
    pcap_t *p = pcap_open_dead(DLT_RAW, 1500);
    if (!p) return -2;

    struct bpf_program prog;
    if (pcap_compile(p, &prog, expr, 1, PCAP_NETMASK_UNKNOWN) != 0) {
        pcap_close(p);
        return -1;
    }

    struct pcap_pkthdr hdr = {0};
    hdr.caplen = pkt_len;
    hdr.len = pkt_len;
    int matched = pcap_offline_filter(&prog, &hdr, pkt);

    pcap_freecode(&prog);
    pcap_close(p);
    return matched ? 1 : 0;
}

/* === Framework mínimo === */
static int failed = 0;
#define ASSERT_EQ(actual, expected, name) \
    do { int _a = (actual); int _e = (expected); \
        if (_a != _e) { printf("FAIL: %s — got %d, expected %d\n", (name), _a, _e); failed++; } \
        else { printf("PASS: %s\n", (name)); } } while (0)

int main(void) {
    uint8_t pkt[1500];
    int len;

    /* === Test 1: filtro UDP por puerto destino — Zoom/Meet RTP === */
    /* Match positivo: UDP con dst_port=19302 */
    len = build_udp_packet(pkt, 50000, 19302, "rtp_payload", 11);
    ASSERT_EQ(eval_filter("udp and dst port 19302", pkt, len), 1,
              "udp dst port 19302 match");

    /* No match: dst_port distinto */
    len = build_udp_packet(pkt, 50000, 19303, "noise", 5);
    ASSERT_EQ(eval_filter("udp and dst port 19302", pkt, len), 0,
              "udp dst port 19303 no match");

    /* No match: TCP con mismo puerto (filtro pide UDP) */
    len = build_tcp_packet(pkt, 50000, 19302);
    ASSERT_EQ(eval_filter("udp and dst port 19302", pkt, len), 0,
              "tcp dst port 19302 no match (filter is UDP)");

    /* === Test 2: filtro complejo con múltiples puertos (Meet) === */
    const char *meet_filter = "udp and (dst port 3478 or dst port 19305)";

    len = build_udp_packet(pkt, 50000, 3478, "stun", 4);
    ASSERT_EQ(eval_filter(meet_filter, pkt, len), 1,
              "meet filter matches udp 3478");

    len = build_udp_packet(pkt, 50000, 19305, "rtp", 3);
    ASSERT_EQ(eval_filter(meet_filter, pkt, len), 1,
              "meet filter matches udp 19305");

    len = build_udp_packet(pkt, 50000, 3479, "wrong", 5);
    ASSERT_EQ(eval_filter(meet_filter, pkt, len), 0,
              "meet filter rejects udp 3479");

    /* === Test 3: filtro TCP por puerto y host === */
    len = build_tcp_packet(pkt, 50000, 443);
    ASSERT_EQ(eval_filter("tcp and dst port 443", pkt, len), 1,
              "tcp dst port 443 match");

    /* UDP en mismo puerto NO matchea filtro TCP */
    len = build_udp_packet(pkt, 50000, 443, "quic?", 5);
    ASSERT_EQ(eval_filter("tcp and dst port 443", pkt, len), 0,
              "udp dst port 443 no match (filter is TCP)");

    /* === Test 4: filtro por dst host (IP literal) === */
    /* Construido con dst 1.2.3.4 */
    len = build_udp_packet(pkt, 50000, 5004, "rtp", 3);
    ASSERT_EQ(eval_filter("udp and dst host 1.2.3.4", pkt, len), 1,
              "filter dst host 1.2.3.4 match");

    ASSERT_EQ(eval_filter("udp and dst host 5.6.7.8", pkt, len), 0,
              "filter dst host 5.6.7.8 no match");

    /* === Test 5: sintaxis BPF inválida — pcap_compile falla === */
    ASSERT_EQ(eval_filter("this is not valid bpf at all", pkt, len), -1,
              "invalid bpf syntax returns -1 (no crash)");

    ASSERT_EQ(eval_filter("udp dst", pkt, len), -1,
              "incomplete bpf returns -1");

    /* === Test 6: filtro por rango de puertos (UDP RTP típico 16384-32767) === */
    len = build_udp_packet(pkt, 50000, 20000, "rtp", 3);
    ASSERT_EQ(eval_filter("udp and portrange 16384-32767", pkt, len), 1,
              "udp portrange match (port in range)");

    len = build_udp_packet(pkt, 50000, 50000, "noise", 5);
    /* OJO: src_port=50000, dst_port=50000 — portrange matchea cualquiera de los dos */
    ASSERT_EQ(eval_filter("udp and portrange 16384-32767", pkt, len), 0,
              "udp portrange no match (port out of range)");

    /* === Test 7: filtro vacío (sintaxis válida que matchea todo) === */
    /* "ip" matchea cualquier paquete IP */
    len = build_udp_packet(pkt, 1, 2, "x", 1);
    ASSERT_EQ(eval_filter("ip", pkt, len), 1, "filter 'ip' matches all IP pkts");

    if (failed > 0) {
        printf("---\n%d FAILURES\n", failed);
        return 1;
    }
    printf("---\nALL_TESTS_PASSED\n");
    return 0;
}
