
#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

#ifndef _TR_UDP_H_
#define _TR_UDP_H_

#include <inttypes.h>
#include <event.h>
#include "transmission.h"


/**
 * Structures used in the UDP tracker protocol
 * see: http://www.rasterbar.com/products/libtorrent/udp_tracker_protocol.html
 */


struct tr_udp_connect_request {
	int64_t connection_id;
	int32_t action;
	int32_t transaction_id;
} __attribute__((packed));

struct tr_udp_connnect_reply
{
	int32_t action;
	int32_t transaction_id;
	int64_t connection_id;
} __attribute__((packed));

struct tr_udp_announce_request
{
	int64_t connection_id;
	int32_t action;
	int32_t transaction_id;
	int8_t info_hash[20];
	int8_t peer_id[20];
	int64_t downloaded;
	int64_t left;
	int64_t uploaded;
	int32_t event;
	uint32_t ip;
	uint32_t key;
	int32_t num_want;
	uint16_t port;
	uint16_t extensions;
} __attribute__((packed));

struct tr_udp_announce_reply
{
	int32_t action;
	int32_t transaction_id;
	int32_t interval;
	int32_t leechers;
	int32_t seeders;
} __attribute__((packed));

struct tr_udp_announce_reply_rest
{
	int32_t ip;
	uint16_t port;
	} __attribute__((packed));

struct tr_udp_scrape_request
{
	int64_t connection_id;
	int32_t action;
	int32_t transaction_id;
} __attribute__((packed));

struct tr_udp_scrape_request_rest
{
	int8_t info_hash[20];
} __attribute__((packed));

struct tr_udp_scrape_reply
{
	int32_t action;
	int32_t transaction_id;
} __attribute__((packed));

struct tr_udp_scrape_reply_rest
{
	int32_t complete;
	int32_t downloaded;
	int32_t incomplete;
} __attribute__((packed));

struct tr_udp_error_reply
{
	int32_t action;
	int32_t transaction_id;
	int8_t error_string[0];
};


#define TR_UDP_ACTION_CONNECT	0
#define TR_UDP_ACTION_ANNOUNCE	1
#define TR_UDP_ACTION_SCRAPE	2
#define TR_UDP_ACTION_ERROR		3

/**
 * State tracking of the UDP request
 */

struct tr_udp_state
{
	int sockfd;
	struct event ev;

	int64_t connection_id;
	int32_t action;
	int32_t transaction_id;
};

void tr_udpAnnounce(const tr_tracker_info * address, int reqtype);

#endif /* _TR_UDP_H_ */
