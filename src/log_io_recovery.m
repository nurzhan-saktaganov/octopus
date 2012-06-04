/*
 * Copyright (C) 2010, 2011, 2012 Mail.RU
 * Copyright (C) 2010, 2011, 2012 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#import <util.h>
#import <fiber.h>
#import <object.h>
#import <log_io.h>
#import <palloc.h>
#import <say.h>
#import <pickle.h>
#import <tbuf.h>
#import <net_io.h>

#include <third_party/crc32.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <poll.h>
#include <sysexits.h>
#include <netinet/in.h>
#include <arpa/inet.h>

@implementation Recovery

- (const char *)status { return status; };
- (ev_tstamp)lag { return lag; };
- (ev_tstamp)last_update_tstamp { return last_update_tstamp; };

- (i64) scn { return scn; }
- (i64) next_scn { return ++scn; }
- (void) set_scn:(i64)scn_ { scn = scn_; }
- (bool) auto_scn { return true; }

/* this little hole shouldn't be used too much */
int
read_log(const char *filename, void (*handler)(struct tbuf *out, u16 tag, struct tbuf *row))
{
	XLog *l;
	struct tbuf *row;
	XLogDir *dir;

	if (strstr(filename, ".xlog")) {
                dir = [[WALDir alloc] init_dirname:NULL];
	} else if (strstr(filename, ".snap")) {
                dir = [[SnapDir alloc] init_dirname:NULL];
	} else {
		say_error("don't know what how to read `%s'", filename);
		return -1;
	}

	l = [dir open_for_read_filename:filename];
	if (l == nil) {
		say_syserror("unable to open filename `%s'", filename);
		return -1;
	}
	fiber->pool = l->pool;
	while ((row = [l next_row])) {
		struct tbuf *out = tbuf_alloc(l->pool);
		struct row_v12 *v12 = row_v12(row);

		tbuf_printf(out, "lsn:%" PRIi64 " scn:%" PRIi64 " tm:%.3f t:%s %s ",
			    v12->lsn, v12->scn, v12->tm, xlog_tag_to_a(v12->tag),
			    sintoa((void *)&v12->cookie));

		struct tbuf row_data = TBUF(v12->data, v12->len, NULL);

		switch (v12->tag) {
		case snap_initial_tag:
			tbuf_printf(out, "initial row");
			break;
		case snap_tag:
		case wal_tag:
			handler(out, v12->tag, &row_data);
			break;
		default:
			tbuf_printf(out, "UNKNOWN");
		}
		printf("%.*s\n", tbuf_len(out), (char *)out->ptr);
		prelease_after(l->pool, 128 * 1024);
	}

	if (!l->eof) {
		say_error("binary log `%s' wasn't correctly closed", filename);
		return -1;
	}
	return 0;
}


- (void)
validate_row:(struct tbuf *)row
{
	u16 tag = row_v12(row)->tag;
	if (tag == snap_initial_tag ||
	    tag == snap_tag ||
	    tag == snap_final_tag)
		return;

	if (row_v12(row)->lsn != lsn + 1) {
		if (!cfg.io_compat)
			raise("lsn sequence has gap after %"PRIi64 " -> %"PRIi64,
			      lsn, row_v12(row)->lsn);
		else
			say_warn("lsn sequence has gap after %"PRIi64 " -> %"PRIi64,
				 lsn, row_v12(row)->lsn);
	}
}

- (struct tbuf *)
dummy_row_lsn:(i64)lsn_ scn:(i64)scn_ tag:(u16)tag
{
	struct tbuf *b = tbuf_alloc(fiber->pool);
	tbuf_ensure(b, sizeof(struct row_v12));
	tbuf_append(b, NULL, sizeof(struct row_v12));

	row_v12(b)->lsn = lsn_;
	row_v12(b)->scn = scn_;
	row_v12(b)->tm = ev_now();
	row_v12(b)->tag = tag;
	row_v12(b)->cookie = default_cookie;
	row_v12(b)->len = 0;
	row_v12(b)->data_crc32c = crc32c(0, (unsigned char *)"", 0);
	row_v12(b)->header_crc32c =
		crc32c(0, (unsigned char *)row_v12(b) + sizeof(row_v12(b)->header_crc32c),
		       sizeof(row_v12(b)) - sizeof(row_v12(b)->header_crc32c));
	return b;
}

- (void)
recover_row:(struct tbuf *)row
{
	i64 row_lsn = row_v12(row)->lsn;
	i64 row_scn = row_v12(row)->scn;
	u16 tag = row_v12(row)->tag;
	ev_tstamp tm = row_v12(row)->tm;

	@try {
		say_debug("%s: lsn:%"PRIi64" scn:%"PRIi64" tag:%s",
			  __func__, row_v12(row)->lsn, row_scn, xlog_tag_to_a(tag));
		if (row_lsn > 0)
			lsn = row_lsn;

		tbuf_ltrim(row, sizeof(struct row_v12)); /* drop header */
		recover_row(row, tag);
		switch (tag) {
		case wal_tag:
			assert(row_scn > 0);
			scn = row_scn; /* each wal_tag row represent a single atomic change */
			lag = ev_now() - tm;
			last_update_tstamp = ev_now();
			break;
		case snap_initial_tag:
			break;
		case snap_final_tag:
			scn = row_scn;
			break;
		default:
			break;
		}
	}
	@catch (Error *e) {
		say_error("Recovery: %s at %s:%i", e->reason, e->file, e->line);
		@throw;
	}
}

- (i64)
recover_snap
{
	XLog *snap = nil;
	struct tbuf *row;

	struct palloc_pool *saved_pool = fiber->pool;
	@try {
		i64 snap_lsn = [snap_dir greatest_lsn];
		if (snap_lsn == -1)
			raise("snap_dir reading failed");

		if (snap_lsn < 1)
			return 0;

		snap = [snap_dir open_for_read:snap_lsn];
		if (snap == nil)
			raise("can't find/open snapshot");

		say_info("recover from `%s'", snap->filename);

		fiber->pool = snap->pool;

		if ([snap isKindOf:[XLog11 class]])
			[self recover_row:[self dummy_row_lsn:0
							  scn:0
							  tag:snap_initial_tag]];
		while ((row = [snap next_row])) {
			if (unlikely(row_v12(row)->tag == snap_final_tag)) {
				[self recover_row:row];
				continue;
			}
			[self validate_row:row];
			[self recover_row:row];
			prelease_after(snap->pool, 128 * 1024);
		}

		/* old v11 snapshot, scn == lsn from filename */
		if ([snap isKindOf:[XLog11 class]])
			[self recover_row:[self dummy_row_lsn:snap_lsn
							  scn:snap_lsn
							  tag:snap_final_tag]];

		if (!snap->eof)
			raise("unable to fully read snapshot");
	}
	@finally {
		fiber->pool = saved_pool;
		[snap close];
		snap = nil;
	}
	say_info("snapshot recovered, lsn:%"PRIi64 " scn:%"PRIi64, lsn, scn);
	return lsn;
}

- (void)
recover_wal:(XLog *)l
{
	struct tbuf *row = NULL;

	struct palloc_pool *saved_pool = fiber->pool;
	fiber->pool = l->pool;
	@try {
		while ((row = [l next_row])) {
			if (row_v12(row)->lsn > lsn) {
				[self validate_row:row];
				[self recover_row:row];
			}

			prelease_after(l->pool, 128 * 1024);
		}
	}
	@finally {
		fiber->pool = saved_pool;
	}
	say_debug("after recover wal:%s lsn:%"PRIi64, l->filename, lsn);
}

- (XLog *)
next_wal
{
	return [wal_dir open_for_read:lsn + 1];
}

/*
 * this function will not close r->current_wal if recovery was successful
 */
- (void)
recover_remaining_wals
{
	i64 wal_greatest_lsn = [wal_dir greatest_lsn];
	if (wal_greatest_lsn == -1)
		raise("wal_dir reading failed");

	/* if the caller already opened WAL for us, recover from it first */
	if (current_wal != nil)
		goto recover_current_wal;

	while (lsn < wal_greatest_lsn) {
		if (current_wal != nil) {
                        say_warn("wal `%s' wasn't correctly closed, lsn:%"PRIi64" scn:%"PRIi64,
				 current_wal->filename, lsn, scn);
                        [current_wal close];
                        current_wal = nil;
		}

		current_wal = [self next_wal];
		if (current_wal == nil)
			break;
		if (!current_wal->valid) /* unable to read & parse header */
			break;

		say_info("recover from `%s'", current_wal->filename);
	recover_current_wal:
		[self recover_wal:current_wal];
		if ([current_wal rows] == 0) /* either broken wal or empty inprogress */
			break;

		if (current_wal->eof) {
			say_info("done `%s' lsn:%"PRIi64" scn:%"PRIi64,
				 current_wal->filename, lsn, scn);
			[current_wal close];
			current_wal = nil;
		}
		fiber_gc();
	}
	fiber_gc();

	/*
	 * It's not a fatal error when last WAL is empty,
	 * but if it's in the middle then we lost some logs.
	 */
	if (wal_greatest_lsn > lsn + 1)
		raise("not all WALs have been successfully read! "
		      "greatest_lsn:%"PRIi64" lsn:%"PRIi64" diff:%"PRIi64,
		      wal_greatest_lsn, lsn, wal_greatest_lsn - lsn);
}

- (i64)
recover_cont
{
	if (current_wal != nil)
		say_info("recover from `%s'", current_wal->filename);

	[self recover_remaining_wals];
	[self recover_follow:cfg.wal_dir_rescan_delay]; /* FIXME: make this conf */
	say_info("wals recovered, lsn:%"PRIi64" scn:%"PRIi64, lsn, scn);
	strcpy(status, "hot_standby/local");

	/* all curently readable wal rows were read, notify about that */
	if (feeder_addr == NULL || cfg.local_hot_standby)
		[self recover_row:[self dummy_row_lsn:lsn scn:scn tag:wal_final_tag]];

	return lsn;
}

- (i64)
recover_start
{
	say_info("local recovery start");
	[self recover_snap];
	if (scn == 0)
		return 0;
	/*
	 * just after snapshot recovery current_wal isn't known
	 * so find wal which contains record with next lsn
	 */
	current_wal = [wal_dir containg_lsn:lsn + 1];
	return [self recover_cont];
}

- (i64)
recover_start_from_scn:(i64)initial_scn
{
	if (initial_scn == 0) {
		[self recover_snap];
	} else {
		lsn = [wal_dir containg_scn:initial_scn];
		scn = initial_scn;
	}
	current_wal = [wal_dir containg_lsn:lsn + 1];
	return [self recover_cont];
}

static void follow_file(ev_stat *, int);

static void
follow_dir(ev_timer *w, int events __attribute__((unused)))
{
	Recovery *r = w->data;
	[r recover_remaining_wals];

	if (r->current_wal == nil)
		return;

	if (r->current_wal->inprogress && [r->current_wal rows] > 1)
		[r->current_wal reset_inprogress];

	[r->current_wal follow:follow_file];
}

static void
follow_file(ev_stat *w, int events __attribute__((unused)))
{
	Recovery *r = w->data;
	[r recover_wal:r->current_wal];
	if (r->current_wal->eof) {
		say_info("done `%s' lsn:%"PRIi64" scn:%"PRIi64,
			 r->current_wal->filename, r->lsn, [r scn]);
		[r->current_wal close];
		r->current_wal = nil;
		follow_dir((ev_timer *)w, 0);
		return;
	}

	if (r->current_wal->inprogress && [r->current_wal rows] > 1) {
		[r->current_wal reset_inprogress];
		[r->current_wal follow:follow_file];
	}
}

- (void)
recover_follow:(ev_tstamp)wal_dir_rescan_delay
{
	ev_timer_init(&wal_timer, follow_dir,
		      wal_dir_rescan_delay, wal_dir_rescan_delay);
	ev_timer_start(&wal_timer);
	if (current_wal != nil)
		[current_wal follow:follow_file];
}

- (void)
recover_finalize
{
	ev_timer_stop(&wal_timer);
	if (current_wal != nil)
		ev_stat_stop(&current_wal->stat);

	[self recover_remaining_wals];

	if (current_wal != nil && current_wal->inprogress) {
		if ([current_wal rows] < 1) {
			[current_wal inprogress_unlink];
			[current_wal close];
			current_wal = nil;
		} else {
			assert([current_wal rows] == 1);
			if ([current_wal inprogress_rename] != 0)
				panic("can't rename 'inprogress' wal");
		}
	}

	if (current_wal != nil)
                say_warn("wal `%s' wasn't correctly closed", current_wal->filename);

        [current_wal close];
        current_wal = nil;

	if (mh_size(pending_row) != 0)
		panic("pending rows: unable to proceed");
}

- (u32)
remote_handshake:(struct sockaddr_in *)addr conn:(struct conn *)c
{
	bool warning_said = false;
	const int reconnect_delay = 1;
	const char *err = NULL;
	u32 version;

	i64 initial_lsn = 0;

	if (lsn > 0)
		initial_lsn = lsn + 1;

	do {
		if ((c->fd = tcp_connect(addr, NULL, 0)) < 0) {
			err = "can't connect to feeder";
			goto err;
		}

		if (conn_write(c, &initial_lsn, sizeof(initial_lsn)) != sizeof(initial_lsn)) {
			err = "can't write initial lsn";
			goto err;
		}

		while (tbuf_len(c->rbuf) < sizeof(struct iproto_header_retcode) + sizeof(version))
			conn_recv(c);
		struct tbuf *rep = iproto_parse(c->rbuf);
		if (rep == NULL) {
			err = "can't read reply";
			goto err;
		}

		if (iproto_retcode(rep)->ret_code != 0 ||
		    iproto_retcode(rep)->sync != iproto(req)->sync ||
		    iproto_retcode(rep)->msg_code != iproto(req)->msg_code ||
		    iproto_retcode(rep)->len != sizeof(iproto_retcode(rep)->ret_code) + sizeof(version))
		{
			err = "bad reply";
			goto err;
		}
		say_debug("go reply len:%i, rbuf %i", iproto_retcode(rep)->len, tbuf_len(c->rbuf));
		memcpy(&version, iproto_retcode(rep)->data, sizeof(version));
		if (version != default_version && version != version_11) {
			err = "unknown remote version";
			goto err;
		}

		say_crit("succefully connected to feeder");
		say_crit("starting remote recovery from lsn:%" PRIi64, initial_lsn);
		break;

	err:
		if (err != NULL && !warning_said) {
			say_info("%s", err);
			say_info("will retry every %i second", reconnect_delay);
			/* no more WAL rows in near future, notify module about that */
			[self recover_row:[self dummy_row_lsn:lsn scn:scn tag:wal_final_tag]];
			warning_said = true;
		}
		conn_close(c);
		fiber_sleep(reconnect_delay);
	} while (c->fd < 0);

	return version;
}

static bool
contains_full_row_v12(const struct tbuf *b)
{
	return tbuf_len(b) >= sizeof(struct row_v12) &&
		tbuf_len(b) >= sizeof(struct row_v12) + row_v12(b)->len;
}

static bool
contains_full_row_v11(const struct tbuf *b)
{
	return tbuf_len(b) >= sizeof(struct _row_v11) &&
		tbuf_len(b) >= sizeof(struct _row_v11) + _row_v11(b)->len;
}

static struct tbuf *
fetch_row(struct conn *c, u32 version)
{
	struct tbuf *row;
	u32 data_crc;

	switch (version) {
	case 12:
		if (!contains_full_row_v12(c->rbuf))
			return NULL;

		row = tbuf_split(c->rbuf, sizeof(struct row_v12) + row_v12(c->rbuf)->len);
		row->pool = c->rbuf->pool; /* FIXME: this is cludge */

		data_crc = crc32c(0, row_v12(row)->data, row_v12(row)->len);
		if (row_v12(row)->data_crc32c != data_crc)
			raise("data crc32c mismatch");

		return row;
	case 11:
		if (!contains_full_row_v11(c->rbuf))
			return NULL;

		row = tbuf_split(c->rbuf, sizeof(struct _row_v11) + _row_v11(c->rbuf)->len);
		row->pool = c->rbuf->pool;

		data_crc = crc32c(0, _row_v11(row)->data, _row_v11(row)->len);
		if (_row_v11(row)->data_crc32c != data_crc)
			raise("data crc32c mismatch");

		return convert_row_v11_to_v12(row);
	default:
		raise("unexpected version: %i", version);
	}
}

static void
pull_snapshot(Recovery *r, struct conn *c, u32 version)
{
	struct tbuf *row;
	for (;;) {
		if (conn_recv(c) <= 0)
			raise("unexpected eof");
		while ((row = fetch_row(c, version))) {
			switch (row_v12(row)->tag) {
			case snap_initial_tag:
			case snap_tag:
				[r recover_row:row];
				break;
			case snap_final_tag:
				[r recover_row:row];
				[r configure_wal_writer];
				say_debug("saving snapshot");
				if (save_snapshot(NULL, 0) != 0)
					raise("replication failure: failed save snapshot");
				return;
			default:
				raise("unexpected tag %i", row_v12(row)->tag);
			}
		}
		fiber_gc();
	}
}

static void
pull_wal(Recovery *r, struct conn *c, u32 version)
{
	struct tbuf *row, *special_row = NULL, *rows[WAL_PACK_MAX];
	struct wal_pack *pack;

	/* TODO: use designated palloc_pool */
	for (;;) {
		if (conn_recv(c) <= 0)
			raise("unexpected eof");

		int pack_rows = 0;
		i64 remote_scn = 0;
		while ((row = fetch_row(c, version))) {
			remote_scn = row_v12(row)->lsn;
			if (row_v12(row)->tag != wal_tag) {
				special_row = row;
				break;
			}

			rows[pack_rows++] = row;
			if (pack_rows == WAL_PACK_MAX)
				break;
		}

		if (pack_rows > 0) {
			@try {
				for (int j = 0; j < pack_rows; j++) {
					row = rows[j];
					[r recover_row:tbuf_clone(fiber->pool, row)];
				}
			}
			@catch (id e) {
				panic("Replication failure: remote row lsn:%"PRIi64 " scn:%"PRIi64,
				      row_v12(row)->lsn, row_v12(row)->scn);
			}

			int confirmed = 0;
			while (confirmed != pack_rows) {
				pack = [r wal_pack_prepare];
				for (int i = confirmed; i < pack_rows; i++) {
					row = rows[i];
					[r wal_pack_append:pack
						      data:row_v12(row)->data
						       len:row_v12(row)->len
						       scn:row_v12(row)->scn
						       tag:row_v12(row)->tag
						    cookie:row_v12(row)->cookie];
				}
				confirmed += [r wal_pack_submit];
				if (confirmed != pack_rows) {
					say_warn("wal write failed confirmed:%i != sent:%i",
						 confirmed, pack_rows);
					fiber_sleep(0.05);
				}
			}
			say_debug("local scn:%"PRIi64" remote scn:%"PRIi64, [r scn], remote_scn);
			assert([r scn] == remote_scn);
		}

		if (special_row) {
			[r recover_row:special_row];
			special_row = NULL;
		}

		fiber_gc();
	}
}

static void
pull_from_remote(va_list ap)
{
	Recovery *r = va_arg(ap, Recovery *);
	struct sockaddr_in *addr = va_arg(ap, struct sockaddr_in *);
	struct conn c;
	u32 version = 0;

	conn_init(&c, fiber->pool, -1, REF_STATIC);
	palloc_register_gc_root(fiber->pool, &c, conn_gc);


	for (;;) {
		@try {
			if (c.fd < 0)
				version = [r remote_handshake:addr conn:&c];

			if ([r lsn] == 0)
				pull_snapshot(r, &c, version);
			else {
				if (version == 11)
					[r recover_row:[r dummy_row_lsn:[r lsn] tag:wal_final_tag]];
				pull_wal(r, &c, version);
			}
		}
		@catch (Error *e) {
			say_error("replication failure: %s", e->reason);
			conn_close(&c);
			fiber_sleep(1);
			fiber_gc();
		}
	}
}

- (struct fiber *)
recover_follow_remote
{
	char *name;
	name = malloc(64);
	snprintf(name, 64, "remote_hot_standby/%s", feeder_addr);

	remote_puller = fiber_create(name, pull_from_remote, self, feeder);
	if (remote_puller == NULL) {
		free(name);
		return NULL;
	}

	return remote_puller;
}

- (void)
enable_local_writes
{
	[self recover_finalize];
	local_writes = true;

	if (feeder_addr != NULL) {
		if (lsn > 0) /* we're already have some xlogs and recovered from them */
			[self configure_wal_writer];

		[self recover_follow_remote];

		say_info("starting remote hot standby");
		snprintf(status, sizeof(status), "hot_standby/%s", feeder_addr);
	} else {
		[self configure_wal_writer];
		say_info("I am primary");
		strcpy(status, "primary");
	}
}

- (int)
submit:(void *)data len:(u32)data_len scn:(i64)scn_ tag:(u16)tag
{
	if (feeder_addr != NULL)
		raise("replica is readonly");

	return [super submit:data len:data_len scn:scn_ tag:tag];
}

- (id) init_snap_dir:(const char *)snap_dirname
             wal_dir:(const char *)wal_dirname
{
	snap_dir = [[SnapDir alloc] init_dirname:snap_dirname];
	wal_dir = [[WALDir alloc] init_dirname:wal_dirname];

	snap_dir->recovery = self;
	wal_dir->recovery = self;
	wal_timer.data = self;

	return self;
}

static void
input_dispatch(va_list ap __attribute__((unused)))
{
	for (;;) {
		struct conn *c = ((struct ev_watcher *)yield())->data;
		tbuf_ensure(c->rbuf, 128 * 1024);

		ssize_t r = tbuf_recv(c->rbuf, c->fd);
		if (unlikely(r <= 0)) {
			if (r < 0) {
				if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
					continue;
				say_syserror("%s: recv", __func__);
				panic("WAL writer connection read error");
			} else
				panic("WAL writer connection EOF");
		}

		while (tbuf_len(c->rbuf) > sizeof(u32) * 2 &&
		       tbuf_len(c->rbuf) >= *(u32 *)c->rbuf->ptr)
		{
			struct wal_reply *r = c->rbuf->ptr;
			resume(fid2fiber(r->fid), r);
			tbuf_ltrim(c->rbuf, sizeof(*r));
		}

		if (palloc_allocated(fiber->pool) > 4 * 1024 * 1024)
			palloc_gc(c->pool);
	}
}

- (id) init_snap_dir:(const char *)snap_dirname
             wal_dir:(const char *)wal_dirname
	 recover_row:(void (*)(struct tbuf *, int))recover_row_
        rows_per_wal:(int)wal_rows_per_file
	 feeder_addr:(const char *)feeder_addr_
         fsync_delay:(double)wal_fsync_delay
               flags:(int)flags
  snap_io_rate_limit:(int)snap_io_rate_limit_
{
	/* Recovery object is never released */

        snap_dir = [[SnapDir alloc] init_dirname:snap_dirname];
        wal_dir = [[WALDir alloc] init_dirname:wal_dirname];

	snap_dir->recovery = self;
	wal_dir->recovery = self;
	wal_timer.data = self;

	if ((flags & RECOVER_READONLY) == 0) {
		if (wal_rows_per_file <= 4)
			panic("inacceptable value of 'rows_per_file'");

		wal_dir->rows_per_file = wal_rows_per_file;
		wal_dir->fsync_delay = wal_fsync_delay;
		snap_io_rate_limit = snap_io_rate_limit_ * 1024 * 1024;

		wal_writer = spawn_child("wal_writer", wal_disk_writer, self);

		ev_io_init(&wal_writer->c->out,
			   (void *)fiber_create("wal_writer/output_flusher", service_output_flusher),
			   wal_writer->c->fd, EV_WRITE);

		struct fiber *dispatcher = fiber_create("wal_writer/input_dispatcher", input_dispatch);
		ev_io_init(&wal_writer->c->in, (void *)dispatcher, wal_writer->c->fd, EV_READ);

		ev_set_priority(&wal_writer->c->in, 1);
		ev_set_priority(&wal_writer->c->out, 1);

		ev_io_start(&wal_writer->c->in);

	}

	recover_row = recover_row_;
	pending_row = mh_i64_init();

	if (feeder_addr_ != NULL) {
		feeder_addr = feeder_addr_;

		say_crit("configuring remote hot standby, WAL feeder %s", feeder_addr);

		feeder = malloc(sizeof(struct sockaddr_in));
		if (atosin(feeder_addr, feeder) == -1 || feeder->sin_addr.s_addr == INADDR_ANY)
			panic("bad feeder_addr: `%s'", feeder_addr);
	}

	return self;
}

@end

register_source();
