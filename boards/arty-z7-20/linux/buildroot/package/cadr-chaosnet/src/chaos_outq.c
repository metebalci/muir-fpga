// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The queue of things a session wants sent: `muir`'s `Vec<Out>` as a list.
//
// Its own translation unit rather than a corner of `chaos_ncp.c`, because
// every service uses it and `chaos_test_file.c` drives a session with no
// transport behind it at all --- which is how the FILE service is held to
// muir without a cable, a socket or a board.

#include "chaos_ncp.h"

#include <stdlib.h>
#include <string.h>

#include <cadr/cadr_log.h>

struct chaos_out *chaos_outq_push(struct chaos_outq *q, enum chaos_out_kind kind)
{
	struct chaos_out *o = calloc(1, sizeof *o);
	if (!o) {
		say("out of memory queueing a packet");
		return NULL;
	}
	o->kind = kind;
	o->next = NULL;
	if (q->tail)
		q->tail->next = o;
	else
		q->head = o;
	q->tail = o;
	return o;
}

struct chaos_out *chaos_outq_pop(struct chaos_outq *q)
{
	struct chaos_out *o = q->head;
	if (!o)
		return NULL;
	q->head = o->next;
	if (!q->head)
		q->tail = NULL;
	o->next = NULL;
	return o;
}

void chaos_outq_clear(struct chaos_outq *q)
{
	struct chaos_out *o;
	while ((o = chaos_outq_pop(q)))
		free(o);
}

int chaos_out_data(struct chaos_outq *q, uint8_t op, const void *bytes, unsigned len)
{
	// A session that offers more than a packet carries is a bug in the
	// session, not something to split here: the FILE service chunks its
	// own output because only it knows where a chunk may end.
	if (len > CHAOS_PKT_MAX_DATA) {
		say("a session offered %u bytes, and a packet carries %u", len,
		    CHAOS_PKT_MAX_DATA);
		return -1;
	}
	struct chaos_out *o = chaos_outq_push(q, CHAOS_OUT_DATA);
	if (!o)
		return -1;
	o->op = op;
	o->len = (uint16_t)len;
	if (len)
		memcpy(o->bytes, bytes, len);
	return 0;
}

int chaos_out_eof(struct chaos_outq *q)
{
	return chaos_outq_push(q, CHAOS_OUT_EOF) ? 0 : -1;
}

int chaos_out_close(struct chaos_outq *q, const char *reason)
{
	struct chaos_out *o = chaos_outq_push(q, CHAOS_OUT_CLOSE);
	if (!o)
		return -1;
	snprintf(o->text, sizeof o->text, "%s", reason ? reason : "");
	return 0;
}

int chaos_out_connect(struct chaos_outq *q, uint16_t host, const char *contact,
		      struct chaos_session *session)
{
	struct chaos_out *o = chaos_outq_push(q, CHAOS_OUT_CONNECT);
	if (!o)
		return -1;
	o->host = host;
	o->session = session;
	snprintf(o->text, sizeof o->text, "%s", contact ? contact : "");
	return 0;
}
