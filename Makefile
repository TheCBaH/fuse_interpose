ID_OFFSET:=$(shell id -u docker 2</dev/null || echo 0)
UID:=$(shell expr $$(id -u) - ${ID_OFFSET})
GID:=$(shell expr $$(id -g) - ${ID_OFFSET})
USER:=$(shell id -un)
WORKSPACE=$(shell pwd)
TERMINAL:=$(shell test -t 0 && echo t)
THIS_DIR:=${PWD}
UI?=y

opam:
	docker build --build-arg USERID=${UID} --build-arg UI=${UI} --build-arg GROUPID=${GID} --build-arg USERNAME=${USER} --build-arg HTTP_PROXY=${http_proxy} -f Dockerfile-$(basename $@) -t $(basename $@) .

opam.run:
	docker run --name $(basename $@) --rm -it -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@)

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

test.fuse_interposer_c:opam.fuse_interposer_c
	fusermount -u /tmp/mnt || true
	mkdir -p /tmp/mnt
	_build/default/mtime.exe --db /tmp/pwd.db --path ${THIS_DIR}
	./fuse_interposer_c --mtime /tmp/pwd.db --mtime-prefix ${THIS_DIR}/ -o gid=1  -o uid=$(shell id -u) -o ro -o modules=subdir -o subdir=${THIS_DIR} /tmp/mnt
	ls -al --full-time ${THIS_DIR} >/tmp/ls.orig
	ls -al --full-time /tmp/mnt >/tmp/ls.mtime
	time diff -r --no-dereference /${THIS_DIR} /tmp/mnt
	fusermount -u /tmp/mnt
	diff -u  /tmp/ls.orig /tmp/ls.mtime || true
	rm /tmp/ls.orig /tmp/ls.mtime /tmp/pwd.db
	_build/default/mtime.exe --db bin.db --path /bin
	./fuse_interposer_c --mtime bin.db --mtime-prefix /bin/ -o gid=1  -o uid=$(shell id -u) -o ro -o modules=subdir -o subdir=/bin /tmp/mnt
	time diff -r /bin /tmp/mnt
	ls -al --full-time /bin >/tmp/ls.orig
	ls -al --full-time /tmp/mnt >/tmp/ls.mtime
	fusermount -u /tmp/mnt
	diff -u /tmp/ls.orig /tmp/ls.mtime || true
	_build/default/mtime.exe --db share.db --path /usr/share
	./fuse_interposer_c --mtime share.db --mtime-prefix /usr/share/ -o gid=1  -o uid=$(shell id -u) -o ro -o modules=subdir -o subdir=/usr/share /tmp/mnt
	du -sh /usr/share
	du -sh /tmp/mnt
	time diff -r --no-dereference /usr/share /tmp/mnt
	fusermount -u /tmp/mnt
	./fuse_interposer_c -o gid=1  -o uid=$(shell id -u) -o ro -o modules=subdir -o subdir=/usr/share /tmp/mnt
	time diff -r --no-dereference /usr/share /tmp/mnt
	fusermount -u /tmp/mnt

clean:
	rm -rf /tmp/mnt
	rm -rf _build
	rm -f pwd.db share.db fuse_interposer_c
