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
	docker run --rm -it -w /src $(basename $@)
