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
	docker run --name $(basename $@) --rm -i -w ${THIS_DIR} -v${THIS_DIR}:${THIS_DIR} $(basename $@) make $(subst .,,$(suffix $@))

test.fuse_interposer_c:opam.fuse_interposer_c
	fusermount -u /tmp/mnt || true
	mkdir -p /tmp/mnt
	./fuse_interposer_c -o gid=1  -o uid=$(shell id -u) -o ro -o modules=subdir -o subdir=/home /tmp/mnt
	ls -al --full-time /tmp/mnt
	fusermount -u /tmp/mnt
	./fuse_interposer_c -o gid=1  -o uid=$(shell id -u) -o ro -o modules=subdir -o subdir=/bin /tmp/mnt
	time diff -r /bin /tmp/mnt
	fusermount -u /tmp/mnt
	./fuse_interposer_c -o gid=1  -o uid=$(shell id -u) -o ro -o modules=subdir -o subdir=/usr/share /tmp/mnt
	time diff -r --no-dereference /usr/share /tmp/mnt
	fusermount -u /tmp/mnt

clean:
	rm -rf /tmp/mnt
