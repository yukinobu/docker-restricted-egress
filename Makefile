SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

PACKAGE := docker-restricted-egress
VERSION := $(shell sed -n 's/^Version: //p' debian/control)
BUILD_DIR := build
STAGE := $(BUILD_DIR)/package
DEB := $(PACKAGE)_$(VERSION)_all.deb
SOURCES := $(shell find src config systemd debian -type f) Makefile README.md README-dev.md

.PHONY: all build test check install clean
all: build
build: $(DEB)

$(DEB): $(SOURCES)
	rm -rf "$(STAGE)"
	$(MAKE) install DESTDIR="$(abspath $(STAGE))"
	install -d "$(STAGE)/DEBIAN"
	install -m 0644 debian/control debian/conffiles "$(STAGE)/DEBIAN/"
	install -m 0755 debian/preinst debian/postinst debian/prerm debian/postrm "$(STAGE)/DEBIAN/"
	dpkg-deb --root-owner-group --build "$(STAGE)" "$@"

# Staging only: host installation must go through apt/dpkg maintainer scripts.
install:
	@test -n "$(DESTDIR)" || { echo 'Use apt to install the .deb; make install requires DESTDIR.' >&2; exit 1; }
	install -D -m 0755 src/firewall "$(DESTDIR)/usr/libexec/$(PACKAGE)/firewall"
	install -D -m 0644 config/$(PACKAGE) "$(DESTDIR)/etc/default/$(PACKAGE)"
	install -D -m 0644 systemd/$(PACKAGE).service "$(DESTDIR)/usr/lib/systemd/system/$(PACKAGE).service"
	install -D -m 0644 systemd/docker.service.d/50-restricted-egress.conf "$(DESTDIR)/usr/lib/systemd/system/docker.service.d/50-restricted-egress.conf"
	install -d -m 0700 "$(DESTDIR)/var/lib/$(PACKAGE)"
	install -D -m 0644 README.md "$(DESTDIR)/usr/share/doc/$(PACKAGE)/README.md"
	install -D -m 0644 README-dev.md "$(DESTDIR)/usr/share/doc/$(PACKAGE)/README-dev.md"

check:
	@for script in src/firewall config/$(PACKAGE) debian/preinst debian/postinst debian/prerm debian/postrm tests/*.sh tests/mocks/*; do bash -n "$$script"; done
	git diff --check
	git diff --cached --check

test: check build
	bash tests/test-firewall.sh
	bash tests/test-package.sh "$(DEB)"

clean:
	rm -rf "$(BUILD_DIR)"
	rm -f $(PACKAGE)_*_all.deb
