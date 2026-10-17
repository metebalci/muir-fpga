// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What the host gives the machine in 253-257, and the three flags that say
// it: `--ethernet-mac`, `--ip-address` and `--ip-gateway`.
//
// **muir's FLAGS, WITH muir's MEANING, DEFAULTS AND REFUSALS** (the Ethernet
// contract, section 3, "Flags"): one flag has one meaning and one default on
// muir and on the boards.  The parsers are muir's `ethernet_socket::parse_mac`,
// `parse_ip_address`, `parse_ip_gateway` and `check_gateway` in C, and their
// refusals are muir's sentences, word for word.  `qed_test --flags` and
// `golden/src/quux_ethernet_device.rs --flags` put the same questions to
// this file and to muir, and the answers must be the same bytes.
//
// The defaults are muir's: 02:00:00:00:00:01, a locally administered
// address, and 169.254.100.2/30 by 169.254.100.1, QUUX's side of the tap
// quux0 and the link's other end.  There is always a gateway: on the
// address's subnet, not 0.0.0.0 and not QUUX's own address.

#ifndef QED_HOST_H
#define QED_HOST_H

#include <stddef.h>
#include <stdint.h>

struct qed_host {
	uint8_t mac[6];
	// a.b.c.d as a<<24 | b<<16 | c<<8 | d.
	uint32_t address, netmask, gateway;
};

void qed_host_default(struct qed_host *h);

// Each 0, or -1 with muir's refusal in `why`.
int qed_parse_mac(const char *arg, uint8_t mac[6], char *why, size_t len);
int qed_parse_ip_address(const char *arg, uint32_t *address, uint32_t *netmask, char *why,
			 size_t len);
int qed_parse_ip_gateway(const char *arg, uint32_t *gateway, char *why, size_t len);
// `is_default`: the gateway is `--ip-gateway`'s default, not given.
int qed_check_gateway(uint32_t address, uint32_t netmask, uint32_t gateway, int is_default,
		      char *why, size_t len);

// The three as the flags write them.
void qed_mac_text(const uint8_t mac[6], char out[18]);
void qed_ipv4_text(uint32_t a, char out[16]);
unsigned qed_prefix_length(uint32_t netmask);

#endif
