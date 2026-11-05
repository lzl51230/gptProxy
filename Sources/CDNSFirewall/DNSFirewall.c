#include "CDNSFirewall.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/utsname.h>
#include <unistd.h>

/* Darwin's PF ioctl ABI, not shipped in the public SDK. These minimal layouts
 * describe only the state-kill request, not the rule or state-table ABI.
 * Reference: apple-oss-distributions/xnu, bsd/net/pfvar.h, Darwin 23-25.
 * Restrict this operation to audited OS versions; an unknown ABI fails closed.
 * Unlike `pfctl -k host`, the request selects only TCP/UDP destination port 53.
 */
struct cgp_address_match {
    uint8_t addresses[32];
    uint64_t pointer_or_count;
    uint8_t type, flags;
    uint8_t padding[6];
};
union cgp_transport_match {
    struct { uint16_t ports[2]; uint8_t operation; } range;
    uint32_t spi;
};
struct cgp_endpoint_match {
    struct cgp_address_match address;
    uint8_t reserved[3], negated;
    union cgp_transport_match transport;
};
struct cgp_state_kill {
    uint8_t family, protocol, protocol_variant, reserved;
    struct cgp_endpoint_match source, destination;
    char interface_name[16], owner_name[64];
};
_Static_assert(sizeof(struct cgp_address_match) == 48, "Darwin PF address ABI");
_Static_assert(sizeof(struct cgp_endpoint_match) == 64, "Darwin PF endpoint ABI");
_Static_assert(offsetof(struct cgp_state_kill, destination) == 72, "Darwin PF destination offset");
_Static_assert(sizeof(struct cgp_state_kill) == 216, "Darwin PF ioctl ABI");

int cgp_dns_firewall_supported(void) {
    struct utsname name;
    if (uname(&name) != 0) return 0;
    int major = atoi(name.release);
    return major >= 23 && major <= 25;
}

int cgp_clear_dns_states(void) {
    if (!cgp_dns_firewall_supported()) { errno = ENOTSUP; return -1; }
    int descriptor = open("/dev/pf", O_RDWR | O_CLOEXEC);
    if (descriptor < 0) return -1;
    const uint8_t families[] = { AF_INET, AF_INET6 };
    const uint8_t protocols[] = { IPPROTO_TCP, IPPROTO_UDP };
    for (size_t f = 0; f < 2; ++f) {
        for (size_t p = 0; p < 2; ++p) {
            struct cgp_state_kill request = {0};
            request.family = families[f];
            request.protocol = protocols[p];
            request.destination.transport.range.ports[0] = htons(53);
            request.destination.transport.range.operation = 2; /* PF_OP_EQ */
            if (ioctl(descriptor, _IOWR('D', 41, struct cgp_state_kill), &request) != 0) {
                int saved = errno; close(descriptor); errno = saved; return -1;
            }
        }
    }
    close(descriptor);
    return 0;
}
