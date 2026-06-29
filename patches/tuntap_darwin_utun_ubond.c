/*
 * tuntap_darwin.c — implementación utun para macOS (ubond)
 *
 * Adaptado de mlvpn (patches/tuntap_darwin_utun.c) a la API de ubond:
 *   - ubond_pkt_t en lugar de circular_buffer_t
 *   - ubond_pkt_get/release() en lugar de mlvpn_pktbuffer_*
 *   - sin dependencia de buffer.h (que ubond no tiene tras forkear mlvpn)
 *   - división correcta privsep: root_tuntap_open() (root) +
 *     ubond_tuntap_alloc() (unprivileged, IPC vía priv_open_tun)
 *
 * Sustituye el enfoque legacy /dev/tun por la API nativa
 * SYSPROTO_CONTROL + UTUN_CONTROL_NAME, disponible desde macOS 10.6.
 *
 * Aplicar antes de compilar:
 *   cp patches/tuntap_darwin_utun_ubond.c build/ubond/src/tuntap_darwin.c
 */

#include "includes.h"

#include <err.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <net/if_utun.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>

#include "tuntap_generic.h"
#include "privsep.h"
#include "tool.h"
#include "pkt.h"

/* utun añade un prefijo de 4 bytes con la familia (AF_INET big-endian)
 * a cada paquete leído/escrito. */
#define UTUN_HEADER_SIZE 4

static ubond_pkt_t *spair = NULL;

ubond_pkt_t *
ubond_tuntap_read(struct tuntap_s *tuntap)
{
    if (!spair) spair = ubond_pkt_get();
    ubond_pkt_t *p = spair;
    ssize_t ret;

    char buf[DEFAULT_MTU + UTUN_HEADER_SIZE];
    ret = read(tuntap->fd, buf, sizeof(buf));

    if (ret < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return NULL;
    }
    if (ret < 0) {
        fatal("tuntap", "unrecoverable read error");
    } else if (ret == 0) {
        fatalx("tuntap device closed");
    } else if (ret <= UTUN_HEADER_SIZE) {
        log_warnx("tuntap", "%s: packet too small (%zd bytes)",
                  tuntap->devname, ret);
        return NULL;
    }

    ret -= UTUN_HEADER_SIZE;
    if (ret > tuntap->maxmtu) {
        log_warnx("tuntap",
                  "%s: cannot send packet: too big %zd/%d. truncating",
                  tuntap->devname, ret, tuntap->maxmtu);
        ret = tuntap->maxmtu;
    }

    memcpy(p->p.data, buf + UTUN_HEADER_SIZE, ret);
    log_debug("tuntap", "%s < recv %zd bytes", tuntap->devname, ret);
    spair = NULL;
    p->p.len = ret;
    p->p.type = UBOND_PKT_DATA;
    return p;
}

int
ubond_tuntap_write(struct tuntap_s *tuntap, ubond_pkt_t *pkt)
{
    char buf[DEFAULT_MTU + UTUN_HEADER_SIZE];
    uint32_t af_be = htonl(AF_INET);
    int payload_len = pkt->p.len;

    memcpy(buf, &af_be, UTUN_HEADER_SIZE);
    memcpy(buf + UTUN_HEADER_SIZE, pkt->p.data, payload_len);

    ssize_t ret = write(tuntap->fd, buf, payload_len + UTUN_HEADER_SIZE);
    ubond_pkt_release(pkt);

    if (ret < 0) {
        log_warn("tuntap", "%s write error", tuntap->devname);
    } else if (ret != payload_len + UTUN_HEADER_SIZE) {
        log_warnx("tuntap", "%s write error: %zd/%d bytes sent",
                  tuntap->devname, ret - UTUN_HEADER_SIZE, payload_len);
    } else {
        log_debug("tuntap", "%s > sent %d bytes",
                  tuntap->devname, payload_len);
    }
    return ret;
}

/*
 * ubond_tuntap_alloc — llamado por el proceso unprivileged. Pide al
 * proceso priv (vía priv_open_tun) que abra el dispositivo y le pase
 * el fd. Mismo patrón que tuntap_linux.c.
 */
int
ubond_tuntap_alloc(struct tuntap_s *tuntap)
{
    int fd;

    if ((fd = priv_open_tun(tuntap->type,
                            tuntap->devname, tuntap->maxmtu)) <= 0)
        fatalx("failed to open utun device");
    tuntap->fd = fd;
    return fd;
}

/*
 * root_tuntap_open — WARNING: called as root.
 *
 * Abre un utun via SYSPROTO_CONTROL. El kernel asigna utun0, utun1, …
 * (ignoramos `devname` como nombre solicitado, igual que la API utun
 * de macOS — siempre lo asigna el kernel y lo devolvemos). Devuelve
 * un fd o -1 en error. La idea es alcanzar paridad funcional con la
 * versión Linux (que SÍ permite especificar nombre).
 *
 * `tuntapmode` se ignora en macOS (utun = TUN siempre). TAP no soportado.
 *
 * `mtu` se setea aquí también vía socket+SIOCSIFMTU para alinear con
 * Linux que lo hace en el mismo open.
 */
int
root_tuntap_open(int tuntapmode, char *devname, int mtu)
{
    struct ctl_info ctlInfo;
    struct sockaddr_ctl sc;
    int fd, sockfd;

    if (tuntapmode == UBOND_TUNTAPMODE_TAP) {
        warnx("TAP mode not supported on macOS (utun is TUN-only)");
        return -1;
    }

    fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        warn("socket(PF_SYSTEM, SYSPROTO_CONTROL) failed");
        return -1;
    }

    memset(&ctlInfo, 0, sizeof(ctlInfo));
    strlcpy(ctlInfo.ctl_name, UTUN_CONTROL_NAME, sizeof(ctlInfo.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &ctlInfo) < 0) {
        warn("CTLIOCGINFO(%s) failed", UTUN_CONTROL_NAME);
        close(fd);
        return -1;
    }

    memset(&sc, 0, sizeof(sc));
    sc.sc_id = ctlInfo.ctl_id;
    sc.sc_len = sizeof(sc);
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_unit = 0;  /* 0 → kernel asigna primer utunN libre */

    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
        warn("connect to utun failed");
        close(fd);
        return -1;
    }

    /* El kernel ya asignó utunN; recogemos el nombre real. */
    char utunname[UBOND_IFNAMSIZ];
    socklen_t utunname_len = sizeof(utunname);
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME,
                   utunname, &utunname_len) < 0) {
        warn("getsockopt UTUN_OPT_IFNAME failed");
        close(fd);
        return -1;
    }
    strlcpy(devname, utunname, UBOND_IFNAMSIZ);

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    /* MTU: igual que Linux, se setea con SIOCSIFMTU sobre un socket
     * AF_INET separado. utun no acepta el MTU directo en su fd. */
    if ((sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        warn("AF_INET socket creation failed");
    } else {
        struct ifreq ifr;
        memset(&ifr, 0, sizeof(ifr));
        strlcpy(ifr.ifr_name, devname, sizeof(ifr.ifr_name));
        ifr.ifr_mtu = mtu;
        if (ioctl(sockfd, SIOCSIFMTU, &ifr) < 0) {
            warn("unable to set %s mtu=%d (continuing — set from updown)",
                 devname, mtu);
        }
        close(sockfd);
    }

    return fd;
}

int
ubond_tuntap_generic_read(u_char *data, uint32_t len)
{
    /* Stub para mantener la interfaz declarada en tuntap_generic.h.
     * tuntap_linux.c tampoco la implementa; el código real de read
     * está en ubond_tuntap_read arriba. */
    (void)data;
    (void)len;
    return 0;
}
