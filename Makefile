# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Bump these on release - and please check ISO_VERSION for correctness.
VERSION_MAJOR ?= 1
VERSION_MINOR ?= 3
VERSION_BUILD ?= 1
# Default to .0 for higher cache hit rates, as build increments typically don't require new ISO versions
ISO_VERSION ?= v$(VERSION_MAJOR).$(VERSION_MINOR).0

VERSION ?= v$(VERSION_MAJOR).$(VERSION_MINOR).$(VERSION_BUILD)
DEB_VERSION ?= $(VERSION_MAJOR).$(VERSION_MINOR).$(VERSION_BUILD)
RPM_VERSION ?= $(VERSION_MAJOR).$(VERSION_MINOR).$(VERSION_BUILD)
# used by hack/jenkins/release_build_and_upload.sh and KVM_BUILD_IMAGE, see also BUILD_IMAGE below
GO_VERSION ?= 1.12.8

INSTALL_SIZE ?= $(shell du out/minikube-windows-amd64.exe | cut -f1)
BUILDROOT_BRANCH ?= 2018.05.3
REGISTRY?=gcr.io/k8s-minikube

# Get git commit id
COMMIT_NO := $(shell git rev-parse HEAD 2> /dev/null || true)
COMMIT ?= $(if $(shell git status --porcelain --untracked-files=no),"${COMMIT_NO}-dirty","${COMMIT_NO}")

HYPERKIT_BUILD_IMAGE 	?= karalabe/xgo-1.12.x
# NOTE: "latest" as of 2019-08-15. kube-cross images aren't updated as often as Kubernetes
BUILD_IMAGE 	?= k8s.gcr.io/kube-cross:v$(GO_VERSION)-1
ISO_BUILD_IMAGE ?= $(REGISTRY)/buildroot-image
KVM_BUILD_IMAGE ?= $(REGISTRY)/kvm-build-image:$(GO_VERSION)

ISO_BUCKET ?= minikube/iso

MINIKUBE_VERSION ?= $(ISO_VERSION)
MINIKUBE_BUCKET ?= minikube/releases
MINIKUBE_UPLOAD_LOCATION := gs://${MINIKUBE_BUCKET}
MINIKUBE_RELEASES_URL=https://github.com/kubernetes/minikube/releases/download

KERNEL_VERSION ?= 4.15
# latest from https://github.com/golangci/golangci-lint/releases
GOLINT_VERSION ?= v1.17.1
# Limit number of default jobs, to avoid the CI builds running out of memory
GOLINT_JOBS ?= 4
# see https://github.com/golangci/golangci-lint#memory-usage-of-golangci-lint
GOLINT_GOGC ?= 8
# options for lint (golangci-lint)
GOLINT_OPTIONS = --deadline 4m \
	  --build-tags "${MINIKUBE_INTEGRATION_BUILD_TAGS}" \
	  --enable goimports,gocritic,golint,gocyclo,interfacer,misspell,nakedret,stylecheck,unconvert,unparam \
	  --exclude 'variable on range scope.*in function literal|ifElseChain'


export GO111MODULE := on

GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)
GOPATH ?= $(shell go env GOPATH)
BUILD_DIR ?= ./out
$(shell mkdir -p $(BUILD_DIR))

# Use system python if it exists, otherwise use Docker.
PYTHON := $(shell command -v python || echo "docker run --rm -it -v $(shell pwd):/minikube -w /minikube python python")
BUILD_OS := $(shell uname -s)

SHA512SUM=$(shell command -v sha512sum || echo "shasum -a 512")

STORAGE_PROVISIONER_TAG := v1.8.1

# Set the version information for the Kubernetes servers
MINIKUBE_LDFLAGS := -X k8s.io/minikube/pkg/version.version=$(VERSION) -X k8s.io/minikube/pkg/version.isoVersion=$(ISO_VERSION) -X k8s.io/minikube/pkg/version.isoPath=$(ISO_BUCKET) -X k8s.io/minikube/pkg/version.gitCommitID=$(COMMIT)
PROVISIONER_LDFLAGS := "$(MINIKUBE_LDFLAGS) -s -w"

MINIKUBEFILES := ./cmd/minikube/
HYPERKIT_FILES := ./cmd/drivers/hyperkit
STORAGE_PROVISIONER_FILES := ./cmd/storage-provisioner
KVM_DRIVER_FILES := ./cmd/drivers/kvm/

MINIKUBE_TEST_FILES := ./cmd/... ./pkg/...

# npm install -g markdownlint-cli
MARKDOWNLINT ?= markdownlint


MINIKUBE_MARKDOWN_FILES := README.md docs CONTRIBUTING.md CHANGELOG.md

MINIKUBE_BUILD_TAGS := container_image_ostree_stub containers_image_openpgp
MINIKUBE_INTEGRATION_BUILD_TAGS := integration $(MINIKUBE_BUILD_TAGS)

CMD_SOURCE_DIRS = cmd pkg
SOURCE_DIRS = $(CMD_SOURCE_DIRS) test
SOURCE_PACKAGES = ./cmd/... ./pkg/... ./test/...

# kvm2 ldflags
KVM2_LDFLAGS := -X k8s.io/minikube/pkg/drivers/kvm.version=$(VERSION) -X k8s.io/minikube/pkg/drivers/kvm.gitCommitID=$(COMMIT)

# hyperkit ldflags
HYPERKIT_LDFLAGS := -X k8s.io/minikube/pkg/drivers/hyperkit.version=$(VERSION) -X k8s.io/minikube/pkg/drivers/hyperkit.gitCommitID=$(COMMIT)

# $(call DOCKER, image, command)
define DOCKER
	docker run --rm -e GOCACHE=/app/.cache -e IN_DOCKER=1 --user $(shell id -u):$(shell id -g) -w /app -v $(PWD):/app -v $(GOPATH):/go --entrypoint /bin/bash $(1) -c '$(2)'
endef

ifeq ($(BUILD_IN_DOCKER),y)
	MINIKUBE_BUILD_IN_DOCKER=y
endif

# If we are already running in docker,
# prevent recursion by unsetting the BUILD_IN_DOCKER directives.
# The _BUILD_IN_DOCKER variables should not be modified after this conditional.
ifeq ($(IN_DOCKER),1)
	MINIKUBE_BUILD_IN_DOCKER=n
endif

ifeq ($(GOOS),windows)
	IS_EXE = ".exe"
endif


out/minikube$(IS_EXE): out/minikube-$(GOOS)-$(GOARCH)$(IS_EXE)
	cp $< $@

out/minikube-windows-amd64.exe: out/minikube-windows-amd64
	cp out/minikube-windows-amd64 out/minikube-windows-amd64.exe

out/minikube-%: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go  $(shell find $(CMD_SOURCE_DIRS) -type f -name "*.go")
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),/usr/bin/make $@)
else
	GOOS="$(firstword $(subst -, ,$*))" GOARCH="$(lastword $(subst -, ,$*))" go build -tags "$(MINIKUBE_BUILD_TAGS)" -ldflags="$(MINIKUBE_LDFLAGS)" -a -o $@ k8s.io/minikube/cmd/minikube
endif

.PHONY: e2e-%-$(GOARCH)
e2e-%-$(GOARCH): out/minikube-%-$(GOARCH)
	GOOS=$* GOARCH=$(GOARCH) go test -c k8s.io/minikube/test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS)" -o out/$@

e2e-windows-amd64.exe: e2e-windows-amd64
	cp $(BUILD_DIR)/e2e-windows-amd64 $(BUILD_DIR)/e2e-windows-amd64.exe

minikube_iso: # old target kept for making tests happy
	echo $(ISO_VERSION) > deploy/iso/minikube-iso/board/coreos/minikube/rootfs-overlay/etc/VERSION
	if [ ! -d $(BUILD_DIR)/buildroot ]; then \
		mkdir -p $(BUILD_DIR); \
		git clone --depth=1 --branch=$(BUILDROOT_BRANCH) https://github.com/buildroot/buildroot $(BUILD_DIR)/buildroot; \
	fi;
	$(MAKE) BR2_EXTERNAL=../../deploy/iso/minikube-iso minikube_defconfig -C $(BUILD_DIR)/buildroot
	$(MAKE) -C $(BUILD_DIR)/buildroot
	mv $(BUILD_DIR)/buildroot/output/images/rootfs.iso9660 $(BUILD_DIR)/minikube.iso

# Change buildroot configuration for the minikube ISO
.PHONY: iso-menuconfig
iso-menuconfig:
	$(MAKE) -C $(BUILD_DIR)/buildroot menuconfig
	$(MAKE) -C $(BUILD_DIR)/buildroot savedefconfig

# Change the kernel configuration for the minikube ISO
.PHONY: linux-menuconfig
linux-menuconfig:
	$(MAKE) -C $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/ menuconfig
	$(MAKE) -C $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/ savedefconfig
	cp $(BUILD_DIR)/buildroot/output/build/linux-$(KERNEL_VERSION)/defconfig deploy/iso/minikube-iso/board/coreos/minikube/linux_defconfig

out/minikube.iso: $(shell find deploy/iso/minikube-iso -type f)
ifeq ($(IN_DOCKER),1)
	$(MAKE) minikube_iso
else
	docker run --rm --workdir /mnt --volume $(CURDIR):/mnt $(ISO_DOCKER_EXTRA_ARGS) \
		--user $(shell id -u):$(shell id -g) --env HOME=/tmp --env IN_DOCKER=1 \
		$(ISO_BUILD_IMAGE) /usr/bin/make out/minikube.iso
endif

iso_in_docker:
	docker run -it --rm --workdir /mnt --volume $(CURDIR):/mnt $(ISO_DOCKER_EXTRA_ARGS) \
		--user $(shell id -u):$(shell id -g) --env HOME=/tmp --env IN_DOCKER=1 \
		$(ISO_BUILD_IMAGE) /bin/bash

test-iso: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
	go test -v ./test/integration --tags=iso --minikube-args="--iso-url=file://$(shell pwd)/out/buildroot/output/images/rootfs.iso9660"

.PHONY: test-pkg
test-pkg/%: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
	go test -v -test.timeout=60m ./$* --tags="$(MINIKUBE_BUILD_TAGS)"

.PHONY: all
all: cross drivers e2e-cross out/gvisor-addon

.PHONY: drivers
drivers: out/docker-machine-driver-hyperkit out/docker-machine-driver-kvm2

.PHONY: integration
integration: out/minikube
	go test -v -test.timeout=60m ./test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS)" $(TEST_ARGS)

.PHONY: integration-none-driver
integration-none-driver: e2e-linux-$(GOARCH) out/minikube-linux-$(GOARCH)
	sudo -E out/e2e-linux-$(GOARCH) -testdata-dir "test/integration/testdata" -minikube-start-args="--vm-driver=none" -test.v -test.timeout=60m -binary=out/minikube-linux-amd64 $(TEST_ARGS)

.PHONY: integration-versioned
integration-versioned: out/minikube
	go test -v -test.timeout=60m ./test/integration --tags="$(MINIKUBE_INTEGRATION_BUILD_TAGS) versioned" $(TEST_ARGS)

.PHONY: test
test: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
	./test.sh

.PHONY: extract
extract:
	go run cmd/extract/extract.go

# Regenerates assets.go when template files have been updated
pkg/minikube/assets/assets.go: $(shell find deploy/addons -type f)
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),/usr/bin/make $@)
else
	which go-bindata || GO111MODULE=off GOBIN=$(GOPATH)/bin go get github.com/go-bindata/go-bindata/...
	PATH="$(PATH):$(GOPATH)/bin" go-bindata -nomemcopy -o pkg/minikube/assets/assets.go -pkg assets deploy/addons/...
	-gofmt -s -w $@
endif

pkg/minikube/translate/translations.go: $(shell find translations/ -type f)
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(BUILD_IMAGE),/usr/bin/make $@)
else
	which go-bindata || GO111MODULE=off GOBIN=$(GOPATH)/bin go get github.com/go-bindata/go-bindata/...
	PATH="$(PATH):$(GOPATH)/bin" go-bindata -nomemcopy -o pkg/minikube/translate/translations.go -pkg translate translations/...
	-gofmt -s -w $@
endif
	@#golint: Json should be JSON (compat sed)
	@sed -i -e 's/Json/JSON/' $@ && rm -f ./-e

.PHONY: cross
cross: out/minikube-linux-$(GOARCH) out/minikube-darwin-amd64 out/minikube-windows-amd64.exe

.PHONY: windows
windows: out/minikube-windows-amd64.exe

.PHONY: darwin
darwin: out/minikube-darwin-amd64

.PHONY: linux
linux: out/minikube-linux-$(GOARCH)

.PHONY: e2e-cross
e2e-cross: e2e-linux-amd64 e2e-darwin-amd64 e2e-windows-amd64.exe

.PHONY: checksum
checksum:
	for f in out/minikube-linux-$(GOARCH) out/minikube-darwin-amd64 out/minikube-windows-amd64.exe out/minikube.iso \
		 out/docker-machine-driver-kvm2 out/docker-machine-driver-hyperkit; do \
		if [ -f "$${f}" ]; then \
			openssl sha256 "$${f}" | awk '{print $$2}' > "$${f}.sha256" ; \
		fi ; \
	done

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	rm -f pkg/minikube/assets/assets.go
	rm -f pkg/minikube/translate/translations.go
	rm -rf ./vendor

.PHONY: gendocs
gendocs: out/docs/minikube.md

.PHONY: fmt
fmt:
	@gofmt -s -w $(SOURCE_DIRS)

.PHONY: gofmt
gofmt:
	@gofmt -s -l $(SOURCE_DIRS)
	@test -z "`gofmt -s -l $(SOURCE_DIRS)`"

.PHONY: vet
vet:
	@go vet $(SOURCE_PACKAGES)

.PHONY: golint
golint:
	@golint -set_exit_status $(SOURCE_PACKAGES)

.PHONY: gocyclo
gocyclo:
	@gocyclo -over 15 `find $(SOURCE_DIRS) -type f -name "*.go"`

out/linters/golangci-lint:
	mkdir -p out/linters
	curl -sfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b out/linters $(GOLINT_VERSION)

# this one is meant for local use
.PHONY: lint
lint: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go out/linters/golangci-lint
	./out/linters/golangci-lint run ${GOLINT_OPTIONS} ./...

# lint-ci is slower version of lint and is meant to be used in ci (travis) to avoid out of memory leaks.
.PHONY: lint-ci
lint-ci: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go out/linters/golangci-lint
	GOGC=${GOLINT_GOGC} ./out/linters/golangci-lint run \
	--concurrency ${GOLINT_JOBS} ${GOLINT_OPTIONS} ./...

.PHONY: reportcard
reportcard:
	goreportcard-cli -v
	# "disabling misspell on large repo..."
	-misspell -error $(SOURCE_DIRS)

.PHONY: mdlint
mdlint:
	@$(MARKDOWNLINT) $(MINIKUBE_MARKDOWN_FILES)

out/docs/minikube.md: $(shell find cmd) $(shell find pkg/minikube/constants) pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
	go run -ldflags="$(MINIKUBE_LDFLAGS)" -tags gendocs hack/help_text/gen_help_text.go

out/minikube_$(DEB_VERSION).deb: out/minikube-linux-amd64
	cp -r installers/linux/deb/minikube_deb_template out/minikube_$(DEB_VERSION)
	chmod 0755 out/minikube_$(DEB_VERSION)/DEBIAN
	sed -E -i 's/--VERSION--/'$(DEB_VERSION)'/g' out/minikube_$(DEB_VERSION)/DEBIAN/control
	mkdir -p out/minikube_$(DEB_VERSION)/usr/bin
	cp out/minikube-linux-amd64 out/minikube_$(DEB_VERSION)/usr/bin/minikube
	fakeroot dpkg-deb --build out/minikube_$(DEB_VERSION)
	rm -rf out/minikube_$(DEB_VERSION)

out/minikube-$(RPM_VERSION).rpm: out/minikube-linux-amd64
	cp -r installers/linux/rpm/minikube_rpm_template out/minikube-$(RPM_VERSION)
	sed -E -i 's/--VERSION--/'$(RPM_VERSION)'/g' out/minikube-$(RPM_VERSION)/minikube.spec
	sed -E -i 's|--OUT--|'$(PWD)/out'|g' out/minikube-$(RPM_VERSION)/minikube.spec
	rpmbuild -bb -D "_rpmdir $(PWD)/out" -D "_rpmfilename minikube-$(RPM_VERSION).rpm" \
		 out/minikube-$(RPM_VERSION)/minikube.spec
	rm -rf out/minikube-$(RPM_VERSION)

.PHONY: apt
apt: out/Release

out/Release: out/minikube_$(DEB_VERSION).deb
	( cd out && apt-ftparchive packages . ) | gzip -c > out/Packages.gz
	( cd out && apt-ftparchive release . ) > out/Release

.PHONY: yum
yum: out/repodata/repomd.xml

out/repodata/repomd.xml: out/minikube-$(RPM_VERSION).rpm
	createrepo --simple-md-filenames --no-database \
	-u "$(MINIKUBE_RELEASES_URL)/$(VERSION)/" out

.SECONDEXPANSION:
TAR_TARGETS_linux   := out/minikube-linux-amd64 out/docker-machine-driver-kvm2
TAR_TARGETS_darwin  := out/minikube-darwin-amd64 out/docker-machine-driver-hyperkit
TAR_TARGETS_windows := out/minikube-windows-amd64.exe
out/minikube-%-amd64.tar.gz: $$(TAR_TARGETS_$$*)
	tar -cvzf $@ $^

.PHONY: cross-tars
cross-tars: out/minikube-windows-amd64.tar.gz out/minikube-linux-amd64.tar.gz out/minikube-darwin-amd64.tar.gz
	-cd out && $(SHA512SUM) *.tar.gz > SHA512SUM

out/minikube-installer.exe: out/minikube-windows-amd64.exe
	rm -rf out/windows_tmp
	cp -r installers/windows/ out/windows_tmp
	cp -r LICENSE out/windows_tmp/LICENSE
	awk 'sub("$$", "\r")' out/windows_tmp/LICENSE > out/windows_tmp/LICENSE.txt
	sed -E -i 's/--VERSION_MAJOR--/'$(VERSION_MAJOR)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--VERSION_MINOR--/'$(VERSION_MINOR)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--VERSION_BUILD--/'$(VERSION_BUILD)'/g' out/windows_tmp/minikube.nsi
	sed -E -i 's/--INSTALL_SIZE--/'$(INSTALL_SIZE)'/g' out/windows_tmp/minikube.nsi
	cp out/minikube-windows-amd64.exe out/windows_tmp/minikube.exe
	makensis out/windows_tmp/minikube.nsi
	mv out/windows_tmp/minikube-installer.exe out/minikube-installer.exe
	rm -rf out/windows_tmp

out/docker-machine-driver-hyperkit:
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	$(call DOCKER,$(HYPERKIT_BUILD_IMAGE),CC=o64-clang CXX=o64-clang++ /usr/bin/make $@)
else
	GOOS=darwin CGO_ENABLED=1 go build \
		-ldflags="$(HYPERKIT_LDFLAGS)"   \
		-o $(BUILD_DIR)/docker-machine-driver-hyperkit k8s.io/minikube/cmd/drivers/hyperkit
endif

hyperkit_in_docker:
	rm -f out/docker-machine-driver-hyperkit
	$(call DOCKER,$(HYPERKIT_BUILD_IMAGE),CC=o64-clang CXX=o64-clang++ /usr/bin/make out/docker-machine-driver-hyperkit)

.PHONY: install-hyperkit-driver
install-hyperkit-driver: out/docker-machine-driver-hyperkit
	sudo cp out/docker-machine-driver-hyperkit $(HOME)/bin/docker-machine-driver-hyperkit
	sudo chown root:wheel $(HOME)/bin/docker-machine-driver-hyperkit
	sudo chmod u+s $(HOME)/bin/docker-machine-driver-hyperkit

.PHONY: release-hyperkit-driver
release-hyperkit-driver: install-hyperkit-driver checksum
	gsutil cp $(GOBIN)/docker-machine-driver-hyperkit gs://minikube/drivers/hyperkit/$(VERSION)/
	gsutil cp $(GOBIN)/docker-machine-driver-hyperkit.sha256 gs://minikube/drivers/hyperkit/$(VERSION)/

.PHONY: check-release
check-release:
	go test -v ./deploy/minikube/release_sanity_test.go -tags=release

buildroot-image: $(ISO_BUILD_IMAGE) # convenient alias to build the docker container
$(ISO_BUILD_IMAGE): deploy/iso/minikube-iso/Dockerfile
	docker build $(ISO_DOCKER_EXTRA_ARGS) -t $@ -f $< $(dir $<)
	@echo ""
	@echo "$(@) successfully built"

out/storage-provisioner:
	GOOS=linux go build -o $(BUILD_DIR)/storage-provisioner -ldflags=$(PROVISIONER_LDFLAGS) cmd/storage-provisioner/main.go

.PHONY: storage-provisioner-image
storage-provisioner-image: out/storage-provisioner
ifeq ($(GOARCH),amd64)
	docker build -t $(REGISTRY)/storage-provisioner:$(STORAGE_PROVISIONER_TAG) -f deploy/storage-provisioner/Dockerfile  .
else
	docker build -t $(REGISTRY)/storage-provisioner-$(GOARCH):$(STORAGE_PROVISIONER_TAG) -f deploy/storage-provisioner/Dockerfile-$(GOARCH) .
endif

.PHONY: push-storage-provisioner-image
push-storage-provisioner-image: storage-provisioner-image
ifeq ($(GOARCH),amd64)
	gcloud docker -- push $(REGISTRY)/storage-provisioner:$(STORAGE_PROVISIONER_TAG)
else
	gcloud docker -- push $(REGISTRY)/storage-provisioner-$(GOARCH):$(STORAGE_PROVISIONER_TAG)
endif

.PHONY: out/gvisor-addon
out/gvisor-addon: pkg/minikube/assets/assets.go pkg/minikube/translate/translations.go
	GOOS=linux CGO_ENABLED=0 go build -o $@ cmd/gvisor/gvisor.go

.PHONY: gvisor-addon-image
gvisor-addon-image: out/gvisor-addon
	docker build -t $(REGISTRY)/gvisor-addon:latest -f deploy/gvisor/Dockerfile .

.PHONY: push-gvisor-addon-image
push-gvisor-addon-image: gvisor-addon-image
	gcloud docker -- push $(REGISTRY)/gvisor-addon:latest

.PHONY: release-iso
release-iso: minikube_iso checksum
	gsutil cp out/minikube.iso gs://$(ISO_BUCKET)/minikube-$(ISO_VERSION).iso
	gsutil cp out/minikube.iso.sha256 gs://$(ISO_BUCKET)/minikube-$(ISO_VERSION).iso.sha256

.PHONY: release-minikube
release-minikube: out/minikube checksum
	gsutil cp out/minikube-$(GOOS)-$(GOARCH) $(MINIKUBE_UPLOAD_LOCATION)/$(MINIKUBE_VERSION)/minikube-$(GOOS)-$(GOARCH)
	gsutil cp out/minikube-$(GOOS)-$(GOARCH).sha256 $(MINIKUBE_UPLOAD_LOCATION)/$(MINIKUBE_VERSION)/minikube-$(GOOS)-$(GOARCH).sha256

out/docker-machine-driver-kvm2:
ifeq ($(MINIKUBE_BUILD_IN_DOCKER),y)
	docker inspect -f '{{.Id}} {{.RepoTags}}' $(KVM_BUILD_IMAGE) || $(MAKE) kvm-image
	$(call DOCKER,$(KVM_BUILD_IMAGE),/usr/bin/make $@ COMMIT=$(COMMIT))
	# make extra sure that we are linking with the older version of libvirt (1.3.1)
	test "`strings $@ | grep '^LIBVIRT_[0-9]' | sort | tail -n 1`" = "LIBVIRT_1.2.9"
else
	go build \
		-installsuffix "static" \
		-ldflags="$(KVM2_LDFLAGS)" \
		-tags "libvirt.1.3.1 without_lxc" \
		-o $(BUILD_DIR)/docker-machine-driver-kvm2 \
		k8s.io/minikube/cmd/drivers/kvm
endif
	chmod +X $@

out/docker-machine-driver-kvm2_$(DEB_VERSION).deb: out/docker-machine-driver-kvm2
	cp -r installers/linux/deb/kvm2_deb_template out/docker-machine-driver-kvm2_$(DEB_VERSION)
	chmod 0755 out/docker-machine-driver-kvm2_$(DEB_VERSION)/DEBIAN
	sed -E -i 's/--VERSION--/'$(DEB_VERSION)'/g' out/docker-machine-driver-kvm2_$(DEB_VERSION)/DEBIAN/control
	mkdir -p out/docker-machine-driver-kvm2_$(DEB_VERSION)/usr/bin
	cp out/docker-machine-driver-kvm2 out/docker-machine-driver-kvm2_$(DEB_VERSION)/usr/bin/docker-machine-driver-kvm2
	fakeroot dpkg-deb --build out/docker-machine-driver-kvm2_$(DEB_VERSION)
	rm -rf out/docker-machine-driver-kvm2_$(DEB_VERSION)

out/docker-machine-driver-kvm2-$(RPM_VERSION).rpm: out/docker-machine-driver-kvm2
	cp -r installers/linux/rpm/kvm2_rpm_template out/docker-machine-driver-kvm2-$(RPM_VERSION)
	sed -E -i 's/--VERSION--/'$(RPM_VERSION)'/g' out/docker-machine-driver-kvm2-$(RPM_VERSION)/docker-machine-driver-kvm2.spec
	sed -E -i 's|--OUT--|'$(PWD)/out'|g' out/docker-machine-driver-kvm2-$(RPM_VERSION)/docker-machine-driver-kvm2.spec
	rpmbuild -bb -D "_rpmdir $(PWD)/out" -D "_rpmfilename docker-machine-driver-kvm2-$(RPM_VERSION).rpm" \
		out/docker-machine-driver-kvm2-$(RPM_VERSION)/docker-machine-driver-kvm2.spec
	rm -rf out/docker-machine-driver-kvm2-$(RPM_VERSION)

.PHONY: kvm-image # convenient alias to build the docker container
kvm-image: installers/linux/kvm/Dockerfile
	docker build --build-arg "GO_VERSION=$(GO_VERSION)" -t $(KVM_BUILD_IMAGE) -f $< $(dir $<)
	@echo ""
	@echo "$(@) successfully built"

kvm_in_docker:
	docker inspect -f '{{.Id}} {{.RepoTags}}' $(KVM_BUILD_IMAGE) || $(MAKE) kvm-image
	rm -f out/docker-machine-driver-kvm2
	$(call DOCKER,$(KVM_BUILD_IMAGE),/usr/bin/make out/docker-machine-driver-kvm2 COMMIT=$(COMMIT))

.PHONY: install-kvm-driver
install-kvm-driver: out/docker-machine-driver-kvm2
	cp out/docker-machine-driver-kvm2 $(GOBIN)/docker-machine-driver-kvm2

.PHONY: release-kvm-driver
release-kvm-driver: install-kvm-driver checksum
	gsutil cp $(GOBIN)/docker-machine-driver-kvm2 gs://minikube/drivers/kvm/$(VERSION)/
	gsutil cp $(GOBIN)/docker-machine-driver-kvm2.sha256 gs://minikube/drivers/kvm/$(VERSION)/

site/themes/docsy/assets/vendor/bootstrap/package.js:
	git submodule update -f --init --recursive

# hugo for generating site previews
out/hugo/hugo:
	mkdir -p out
	test -d out/hugo || git clone https://github.com/gohugoio/hugo.git out/hugo
	(cd out/hugo && go build --tags extended)

# Serve the documentation site to localhost
.PHONY: site
site: site/themes/docsy/assets/vendor/bootstrap/package.js out/hugo/hugo
	(cd site && ../out/hugo/hugo serve \
	  --disableFastRender \
	  --navigateToChanged \
	  --ignoreCache \
	  --buildFuture)
