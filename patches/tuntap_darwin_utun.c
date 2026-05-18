/*
 * tuntap_darwin.c — implementación utun para macOS
 *
 * Sustituye el enfoque legacy /dev/tun (requería tuntaposx, un kext
 * incompatible con macOS moderno y Apple Silicon) por la API nativa
 * SYSPROTO_CONTROL + UTUN_CONTROL_NAME, disponible desde macOS 10.6.
 *
 * Es la misma API que usan WireGuard, OpenVPN 2.6+ y todos los clientes
 * VPN modernos en macOS. No necesita extensiones de kernel ni permisos
 * especiales: utun se puede crear sin root.
 *
 * Diferencias respecto a /dev/tun:
 *   - Cada paquete leído/escrito lleva un prefijo de 4 bytes con la
 *     familia del protocolo (AF_INET = 0x00000002 big-endian).
 *   - El nombre de interfaz lo asigna el kernel: utun0, utun1, ...
 *   - No hay /dev/tunX: el fd se obtiene via socket de control.
 *
 * Aplicar antes de compilar:
 *   cp patches/tuntap_darwin_utun.c build/MLVPN/src/tuntap_darwin.c
 */

#include "includes.h"

#include <err.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <net/if_utun.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>

#include "buffer.h"
#include "tuntap_generic.h"
#include "tool.h"
#include "log.h"

/* Los paquetes utun tienen un prefijo de 4 bytes con la familia del protocolo */
#define UTUN_HEADER_SIZE 4

int
mlvpn_tuntap_read(struct tuntap_s *tuntap)
{
    ssize_t ret;
    u_char data[DEFAULT_MTU + UTUN_HEADER_SIZE];

    ret = read(tuntap->fd, data, sizeof(data));
    if (ret < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            fatal("tuntap", "unrecoverable read error");
        return 0;
    } else if (ret == 0) {
        fatalx("tuntap device closed");
    }

    /* Descartar el prefijo de familia — el resto es el paquete IP */
    if (ret <= UTUN_HEADER_SIZE)
        return 0;
    ret -= UTUN_HEADER_SIZE;

    if (ret > tuntap->maxmtu) {
        log_warnx("tuntap",
            "cannot send packet: too big %zd/%d. truncating",
            ret, tuntap->maxmtu);
        ret = tuntap->maxmtu;
    }
    return mlvpn_tuntap_generic_read(data + UTUN_HEADER_SIZE, ret);
}

int
mlvpn_tuntap_write(struct tuntap_s *tuntap)
{
    ssize_t ret;
    mlvpn_pkt_t *pkt;
    circular_buffer_t *buf = tuntap->sbuf;
    u_char data[DEFAULT_MTU + UTUN_HEADER_SIZE];
    uint32_t family;

    if (mlvpn_cb_is_empty(buf))
        fatalx("tuntap_write called with empty buffer");

    pkt = mlvpn_pktbuffer_read(buf);

    /* Anteponer prefijo AF_INET (único protocolo que transporta mlvpn) */
    family = htonl(AF_INET);
    memcpy(data, &family, UTUN_HEADER_SIZE);
    memcpy(data + UTUN_HEADER_SIZE, pkt->data, pkt->len);

    ret = write(tuntap->fd, data, pkt->len + UTUN_HEADER_SIZE);
    if (ret < 0) {
        log_warn("tuntap", "%s write error", tuntap->devname);
    } else {
        ret -= UTUN_HEADER_SIZE;
        if (ret != pkt->len) {
            log_warnx("tuntap", "%s write error: %zd/%d bytes sent",
                tuntap->devname, ret, pkt->len);
        } else {
            log_debug("tuntap", "%s > sent %zd bytes",
                tuntap->devname, ret);
        }
    }
    return ret;
}

/*
 * Abre una interfaz utun específica por número de unidad.
 * devname debe tener formato "utunN" (ej. "utun0").
 * Llamada con privilegios de root en el proceso padre (privsep),
 * o directamente cuando se ejecuta sin root (utun no lo necesita).
 */
int
root_tuntap_open(int tuntapmode, char *devname, int mtu)
{
    struct sockaddr_ctl sc;
    struct ctl_info ctl_info;
    int fd, unit;

    /* Extraer número de unidad de "utunN" */
    if (sscanf(devname, "utun%d", &unit) != 1) {
        log_warnx("tuntap", "nombre de dispositivo inválido: %s "
            "(debe ser utun0, utun1, ...)", devname);
        return -1;
    }

    fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        log_warn("tuntap", "socket(PF_SYSTEM) failed");
        return -1;
    }

    memset(&ctl_info, 0, sizeof(ctl_info));
    strlcpy(ctl_info.ctl_name, UTUN_CONTROL_NAME, sizeof(ctl_info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &ctl_info) < 0) {
        log_warn("tuntap", "ioctl(CTLIOCGINFO) failed");
        close(fd);
        return -1;
    }

    memset(&sc, 0, sizeof(sc));
    sc.sc_id      = ctl_info.ctl_id;
    sc.sc_len     = sizeof(sc);
    sc.sc_family  = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_unit    = (uint32_t)(unit + 1); /* utun0 → sc_unit=1, utun1 → sc_unit=2 */

    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
        /* EBUSY = interfaz ya en uso, el caller probará la siguiente */
        close(fd);
        return -1;
    }

    log_debug("tuntap", "interfaz utun abierta: %s", devname);
    return fd;
}

int
mlvpn_tuntap_alloc(struct tuntap_s *tuntap)
{
    char devname[IFNAMSIZ];
    int fd, i;

    /* Probar utun0..utun15 hasta encontrar una disponible */
    for (i = 0; i < 16; i++) {
        snprintf(devname, sizeof(devname), "utun%d", i);
        fd = priv_open_tun(tuntap->type, devname, tuntap->maxmtu);
        if (fd > 0)
            break;
    }

    if (fd <= 0) {
        log_warnx("tuntap",
            "unable to open any utun0..utun15. "
            "All interfaces may be in use.");
        return fd;
    }

    tuntap->fd = fd;
    strlcpy(tuntap->devname, devname, sizeof(tuntap->devname));
    log_info("tuntap", "created interface `%s'", tuntap->devname);
    return tuntap->fd;
}
