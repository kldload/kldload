SHELL := /bin/bash
VENV := .venv
PY := $(VENV)/bin/python
PIP := $(VENV)/bin/pip
APP := socket_snoop.py
IMAGE := socket-snoop:latest

.PHONY: help setup venv deps test run docker-build docker-run docker-shell service-install service-uninstall clean

help:
	@echo "make setup             - install system deps (Debian/Ubuntu)"
	@echo "make venv              - create Python venv (inherits system site-packages)"
	@echo "make deps              - install pip deps"
	@echo "make test              - run unit tests"
	@echo "sudo make run          - run the monitor (root required)"
	@echo "make docker-build      - build Docker image"
	@echo "sudo make docker-run   - run Docker with host visibility"
	@echo "sudo make service-install  - install & start systemd service"
	@echo "sudo make service-uninstall- stop & remove systemd service"
	@echo "make clean             - remove venv and caches"

setup:
	./install-deps-debian.sh

venv:
	python3 -m venv --system-site-packages $(VENV)
	$(PIP) install --upgrade pip

deps: venv
	$(PIP) install -r requirements.txt

test: deps
	PYTHONPATH=$(shell pwd) $(PY) -m pytest -q -ra -vv

run: deps
	sudo $(PY) $(APP) --log-file /var/log/socket_monitor.log

docker-build:
	DOCKER_BUILDKIT=1 docker build --network host --pull -t $(IMAGE) .

docker-run:
	docker run --rm -it \
	  --privileged \
	  --pid=host \
	  --net=host \
	  -v /lib/modules:/lib/modules:ro \
	  -v /usr/src:/usr/src:ro \
	  -v /sys:/sys:ro \
	  -v /var/log:/var/log \
	  $(IMAGE) \
	  /app/.venv/bin/python /app/$(APP) --log-file /var/log/socket_monitor.log

docker-shell:
	docker run --rm -it --privileged --pid=host --net=host \
	  -v /lib/modules:/lib/modules:ro -v /usr/src:/usr/src:ro -v /sys:/sys:ro \
	  $(IMAGE) /bin/bash

service-install:
	sed -e "s|/opt/socket-snoop|$(shell pwd)/..|g" systemd/socket-snoop.service | \
		sudo tee /etc/systemd/system/socket-snoop.service >/dev/null
	sudo systemctl daemon-reload
	sudo systemctl enable --now socket-snoop.service
	sudo systemctl status socket-snoop.service --no-pager

service-uninstall:
	- sudo systemctl disable --now socket-snoop.service
	- sudo rm -f /etc/systemd/system/socket-snoop.service
	- sudo systemctl daemon-reload

clean:
	rm -rf $(VENV) .pytest_cache __pycache__ *.pyc
