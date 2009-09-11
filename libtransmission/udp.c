
#include <assert.h>
#include <stdlib.h>
#include <sys/socket.h>
 #include <sys/types.h>
     #include <sys/socket.h>
     #include <netdb.h>

#include <event.h>


#include "transmission.h"
#include "udp.h"

static printAddr(struct addrinfo *addr)
{
	char namebuf[100];
	int error;

	error = getnameinfo(addr->ai_addr, addr->ai_addrlen, namebuf, sizeof(namebuf), NULL, 0, NI_NUMERICHOST);
	if (error)
		perror("getnameinfo");

	printf("name: %s\n", namebuf);
}

static int setupSocket(const char *url)
{
	struct addrinfo hints, *res;
	int error, sockfd;

	memset(&hints, 0, sizeof(hints));

	/* set-up hints structure */
	hints.ai_family = PF_INET;
	hints.ai_flags = AI_PASSIVE;
	hints.ai_socktype = SOCK_DGRAM;

	error = getaddrinfo(NULL, "6969", &hints, &res);
	if (error || !res) {
		printf("first getaddrinfo\n");
		perror(gai_strerror(error));
		return -1;
	}
//	printAddr(res);
	sockfd = socket(res->ai_family, res->ai_socktype, 0);
	perror("socket");
//	bind(sockfd, res->ai_addr, res->ai_addrlen);
//	perror("bind");

	hints.ai_flags = 0;

	printf("url: %s\n", url);

	error = getaddrinfo(url, "6969", &hints, &res);
	if (error || !res) {
		printf("second getaddrinfo\n");
		perror(gai_strerror(error));
		return -1;
	}
	printAddr(res);
	error = connect(sockfd, res->ai_addr, res->ai_addrlen);
	printf("connected %d\n", error);
	perror("connect");

	printf("returning socket %d\n", sockfd);

	return sockfd;
}

static void announceCallback(int fd, short event, void * data)
{
	struct tr_udp_state * state = data;

	printf("got a udp announce reply\n");
}

void tr_udpAnnounce(const tr_tracker_info * address, int reqtype)
{
	struct tr_udp_state * state = malloc(sizeof(struct tr_udp_state));
	struct timeval timeout;
	const char *url = "udp://192.168.0.82";
	int ret;

	printf("creating socket to connect with %s\n", address->announce);

	state->sockfd = setupSocket(url + 6);
	event_set(&state->ev, state->sockfd, EV_READ, announceCallback, state);

	state->connection_id = 0x8019012717040000ULL;
	state->action = TR_UDP_ACTION_CONNECT;
	state->transaction_id = random();

	struct tr_udp_connect_request connect_request;
	connect_request.connection_id = state->connection_id;
	connect_request.action = state->action;
	connect_request.transaction_id = state->transaction_id;

	ret = send(state->sockfd, &connect_request, sizeof(connect_request), 0);
	printf("sending request (%d)\n", ret);
	perror("send");

	event_add(&state->ev, &timeout);
}

