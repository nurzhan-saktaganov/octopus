/*
 * Copyright (C) 2011, 2013 Mail.RU
 * Copyright (C) 2011, 2013 Yuriy Vostrikov
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

#ifndef OBJECT_H
#define OBJECT_H

#include <objc/Object.h>
#include <palloc.h>
#include <util.h>

Class object_setClass(id, Class);
size_t class_getInstanceSize(Class class);

@interface Object (Octopus)
+ (id)palloc;
+ (id)palloc_from:(struct palloc_pool *)pool;
- (id)retain;
- (void)release;
- (id)autorelease;
#if !HAVE_OBJC_OBJC_API_H
+ (id)alloc;
- (id)free;
- (id)init;
- (BOOL)isMemberOf:(Class)class;
- (BOOL)isKindOf:(Class)class;
- (BOOL)respondsTo:(SEL)aSel;
+ (Class)class;
+ (const char *)name; /* class name */
- (id)perform:(SEL)aSel;
#endif
@end

#define AUTORELEASE_CHAIN_CAPA 30
struct autorelease_chain {
	u32 cnt;
	struct autorelease_chain *prev;
	id objs[AUTORELEASE_CHAIN_CAPA];
};

/* autorelease_pool - just a pointer into autorelease chain stack */
struct autorelease_pool {
	struct autorelease_chain *chain;
	u32 pos;
};
/* this functions are defined in a fiber.m */
/* pop all pools including `pool` */
void autorelease_pop(struct autorelease_pool *pool);
void autorelease_top();
/* pops autorelease pool and calls palloc_cutoff */
void autorelease_pop_and_cut(struct autorelease_pool *pool);
#define WITH_AUTORELEASE \
	struct autorelease_pool __attribute__((cleanup(autorelease_pop))) AutoPooL = {\
		.chain = fiber->autorelease.current, .pos = fiber->autorelease.current->cnt};
#define WITH_AUTORELEASE_AND_CUTPOINT \
        palloc_register_cut_point(fiber->pool); \
	struct autorelease_pool __attribute__((cleanup(autorelease_pop_and_cut))) AutoPooL = {\
		.chain = fiber->autorelease.current, .pos = fiber->autorelease.current->cnt};
/* calls [obj release] on every object in a pool */
void autorelease_drain(struct autorelease_pool *pool);
id autorelease(id obj);

void scoped_release(id *obj);
#define SCOPE_RELEASED __attribute__((cleanup(scoped_release)))

@interface Error : Object {
@public
	const char *reason;
	char buf[1024];
	unsigned line;
	const char *file;
	char *backtrace;
}
- (id)init:(const char *)reason;
- (id)init_line:(unsigned)line_
           file:(const char *)file_
      backtrace:(const char *)backtrace_
         reason:(const char *)reason_;
- (id)init_line:(unsigned)line
           file:(const char *)file
      backtrace:(const char *)backtrace
         format:(const char *)format, ...;
@end


#define raise_fmt(fmt, ...)						\
	({								\
		say_debug("raise at %s:%i " fmt,			\
			  __FILE__, __LINE__, ##__VA_ARGS__);		\
		@throw [[Error palloc] init_line: __LINE__		\
					    file: __FILE__		\
				       backtrace: tnt_backtrace()	\
					  format:(fmt), ##__VA_ARGS__]; \
	})

#endif
