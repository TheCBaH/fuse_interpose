ID_OFFSET:=$(shell id -u docker 2</dev/null || echo 0)
UID:=$(shell expr $$(id -u) - ${ID_OFFSET})
GID:=$(shell expr $$(id -g) - ${ID_OFFSET})
USER:=$(shell id -un)
WORKSPACE=$(shell pwd)
TERMINAL:=$(shell test -t 0 && echo t)
THIS_DIR:=${PWD}
UI?=y
UBUNTU_VER?=18.04

image=opam

opam:
	docker build ${DOCKER_BUILD_OPTS}\
	 --build-arg GROUPID=${GID}\
	 --build-arg UBUNTU_VER=${UBUNTU_VER}\
	 --build-arg UI=${UI}\
	 --build-arg USERID=${UID}\
	 --build-arg USERNAME=${USER}\
	 --build-arg http_proxy\
	 -f Dockerfile-$(basename $@) -t $@ .

opam.run:
	docker run --rm -it -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@)

opam.perf:
	docker run --cap-add SYS_ADMIN --userns=host --user 0:0 --rm -it -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@) bash -cuex 'cd /tmp;perf stat id'

FUSE_CFLAGS= $(shell pkg-config --cflags fuse) -DFUSE_USE_VERSION=26
FUSE_LDFLAGS= $(shell pkg-config --libs fuse) -lulockmgr

CFLAGS = -Wall -Wextra -Os $(FUSE_CFLAGS) -D_XOPEN_SOURCE=500
LDFLAGS = ${FUSE_LDFLAGS}

fuse_interposer_c: fuse_interposer_c.c
	${CC} -o $@ ${CFLAGS} $< ${LDFLAGS}

opam.fuse_interposer_c:
	docker run --rm -i -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@) make $(subst .,,$(suffix $@))

mtime:
	dune build $@.exe

opam.mtime:
	docker run --rm -i -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@) bash -c 'eval $$(opam env) dune build $(subst .,,$(suffix $@)).exe'
	docker run --rm -i -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@) bash -c 'eval $$(opam env) dune exec ./$(subst .,,$(suffix $@)).exe -- --help'


test.mtime:
	rm -f pwd.db share.db
	time _build/default/mtime.exe --db pwd.db --path ${PWD}
	_build/default/mtime.exe --db pwd.db --print --print-mtime >/dev/null
	time _build/default/mtime.exe --db share.db --path /usr/share
	_build/default/mtime.exe --db share.db --print --print-mtime >/dev/null
	du -sh *.db
	_build/default/mtime.exe --db pwd.db --print|time ./fuse_interposer_c --mtime pwd.db  --mtime-lookup
	_build/default/mtime.exe --db share.db --print|time ./fuse_interposer_c --mtime share.db  --mtime-lookup
	for i in $(shell seq 1 20); do  _build/default/mtime.exe --db share.db --print; done |time --verbose ./fuse_interposer_c --mtime share.db  --mtime-lookup

PERF_EVENTS?="task-clock,context-switches,page-faults,cycles,instructions,branches,raw_syscalls:sys_enter,syscalls:sys_exit_openat,syscalls:sys_exit_newfstatat,syscalls:sys_enter_futex,syscalls:sys_enter_newlstat,syscalls:sys_enter_writev,syscalls:sys_enter_read"

opam.perf_fuse_interposer_c:
	docker run --cap-add SYS_ADMIN --privileged --device /dev/fuse --userns=host --user 0:0 --rm -i${TERMINAL} --tmpfs /tmp -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@) bash -cuex '\
	df -h /tmp;du -sh /usr;mkdir /tmp/usr /tmp/mnt;cp -ap /usr /tmp/usr;./fuse_interposer_c --mtime share.db --root /tmp/usr -o ro /tmp/mnt -f & FUSE=$$!;\
	perf stat -a -e ${PERF_EVENTS} diff -r --no-dereference /tmp/usr/usr /usr;\
	perf stat -e ${PERF_EVENTS} -p $$FUSE & PERF=$$!;\
	cd /tmp;perf stat -a -e ${PERF_EVENTS} diff -r --no-dereference /tmp/usr /tmp/mnt;\
	kill $$FUSE;kill -INT  $$PERF;wait||true;echo umount /tmp/mnt'

test.fuse_interposer_c.base: opam.fuse_interposer_c
	fusermount -u /tmp/mnt || true
	mkdir -p /tmp/mnt
	_build/default/mtime.exe --db /tmp/pwd.db --path ${THIS_DIR}
	./fuse_interposer_c --mtime /tmp/pwd.db --root ${THIS_DIR} -o gid=1  -o uid=$(shell id -u) -o ro /tmp/mnt
	ls -al --full-time ${THIS_DIR} >/tmp/ls.orig
	ls -al --full-time /tmp/mnt >/tmp/ls.mtime
	time diff -r --no-dereference /${THIS_DIR} /tmp/mnt
	fusermount -u /tmp/mnt
	diff -u  /tmp/ls.orig /tmp/ls.mtime || true
	rm /tmp/ls.orig /tmp/ls.mtime /tmp/pwd.db
	_build/default/mtime.exe --db bin.db --path /bin

test.fuse_interposer_c: test.fuse_interposer_c.base
	./fuse_interposer_c --mtime bin.db --root /bin -o gid=1  -o uid=$(shell id -u) -o ro /tmp/mnt
	time diff -r /bin /tmp/mnt
	ls -al --full-time /bin >/tmp/ls.orig
	ls -al --full-time /tmp/mnt >/tmp/ls.mtime
	fusermount -u /tmp/mnt
	diff -u /tmp/ls.orig /tmp/ls.mtime || true

test.fuse_interposer_c-slow:
	fusermount -u /tmp/mnt || true
	mkdir -p /tmp/mnt
	_build/default/mtime.exe --db share.db --path /usr/share
	./fuse_interposer_c --mtime share.db --root /usr/share -o gid=1  -o uid=$(shell id -u) -o ro /tmp/mnt
	du -sh /usr/share
	du -sh /tmp/mnt
	time diff -r --no-dereference /usr/share /tmp/mnt
	fusermount -u /tmp/mnt

clean:
	rm -rf /tmp/mnt
	rm -rf _build
	rm -f pwd.db share.db fuse_interposer_c

%.print:
	echo $($(basename $@))
