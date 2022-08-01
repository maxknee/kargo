SHELL ?= /bin/bash

.DEFAULT_GOAL := build

################################################################################
# Version details                                                              #
################################################################################

# This will reliably return the short SHA1 of HEAD or, if the working directory
# is dirty, will return that + "-dirty"
GIT_VERSION = $(shell git describe --always --abbrev=7 --dirty --match=NeVeRmAtCh)

################################################################################
# Containerized development environment-- or lack thereof                      #
################################################################################

ifneq ($(SKIP_DOCKER),true)
	PROJECT_ROOT := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
	GO_DEV_IMAGE := brigadecore/go-tools:v0.8.0

	GO_DOCKER_CMD := docker run \
		-it \
		--rm \
		-e SKIP_DOCKER=true \
		-e GOCACHE=/workspaces/k8sta/.gocache \
		-v $(PROJECT_ROOT):/workspaces/k8sta \
		-w /workspaces/k8sta \
		$(GO_DEV_IMAGE)

	HELM_IMAGE := brigadecore/helm-tools:v0.4.0

	HELM_DOCKER_CMD := docker run \
	  -it \
		--rm \
		-e SKIP_DOCKER=true \
		-e HELM_PASSWORD=$${HELM_PASSWORD} \
		-v $(PROJECT_ROOT):/workspaces/k8sta \
		-w /workspaces/k8sta \
		$(HELM_IMAGE)
endif

################################################################################
# Docker images and charts we build and publish                                #
################################################################################

ifdef DOCKER_REGISTRY
	DOCKER_REGISTRY := $(DOCKER_REGISTRY)/
endif

ifdef DOCKER_ORG
	DOCKER_ORG := $(DOCKER_ORG)/
endif

ifndef VERSION
	VERSION            := $(GIT_VERSION)
endif

DOCKER_IMAGE_NAME := $(DOCKER_REGISTRY)$(DOCKER_ORG)k8sta:$(VERSION)

ifdef HELM_REGISTRY
	HELM_REGISTRY := $(HELM_REGISTRY)/
endif

ifdef HELM_ORG
	HELM_ORG := $(HELM_ORG)/
endif

HELM_CHART_PREFIX := $(HELM_REGISTRY)$(HELM_ORG)

################################################################################
# Tests                                                                        #
################################################################################

.PHONY: lint
lint:
	$(GO_DOCKER_CMD) golangci-lint run --config golangci.yaml

.PHONY: test-unit
test-unit:
	$(GO_DOCKER_CMD) go test \
		-v \
		-timeout=60s \
		-race \
		-coverprofile=coverage.txt \
		-covermode=atomic \
		./...

.PHONY: lint-chart
lint-chart:
	$(HELM_DOCKER_CMD) sh -c ' \
		cd charts/k8sta && \
		helm dep up && \
		helm lint . \
	'

################################################################################
# Image security                                                               #
################################################################################

.PHONY: scan
scan:
	grype $(DOCKER_IMAGE_NAME) -f high

.PHONY: generate-sbom
generate-sbom:
	syft $(DOCKER_IMAGE_NAME) \
		-o spdx-json \
		--file ./artifacts/k8sta-$(VERSION)-SBOM.json

.PHONY: publish-sbom
publish-sbom: generate-sbom
	ghr \
		-u $(GITHUB_ORG) \
		-r $(GITHUB_REPO) \
		-c $$(git rev-parse HEAD) \
		-t $${GITHUB_TOKEN} \
		-n ${VERSION} \
		${VERSION} ./artifacts/k8sta-$(VERSION)-SBOM.json

################################################################################
# Build                                                                        #
################################################################################

.PHONY: build
build:
	docker buildx build \
		-t $(DOCKER_IMAGE_NAME) \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(GIT_VERSION) \
		--platform linux/amd64,linux/arm64 \
		.

################################################################################
# Publish                                                                      #
################################################################################

.PHONY: publish
publish: push push-chart

.PHONY: push
push:
	docker buildx build \
		-t $(DOCKER_IMAGE_NAME) \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(GIT_VERSION) \
		--platform linux/amd64,linux/arm64 \
		--push \
		.

.PHONY: sign
sign:
	docker pull $(DOCKER_IMAGE_NAME)
	docker trust sign $(DOCKER_IMAGE_NAME)
	docker trust inspect --pretty $(DOCKER_IMAGE_NAME)

.PHONY: push-chart
push-chart:
	$(HELM_DOCKER_CMD) sh	-c ' \
		helm registry login $(HELM_REGISTRY) -u $(HELM_USERNAME) -p $${HELM_PASSWORD} && \
		cd charts/k8sta && \
		helm dep up && \
		helm package . --version $(VERSION) --app-version $(VERSION) && \
		helm push k8sta-$(VERSION).tgz oci://$(HELM_REGISTRY)$(HELM_ORG) \
	'

################################################################################
# Targets to facilitate hacking on K8sTA                                       #
################################################################################

.PHONY: hack-kind-up
hack-kind-up:
	ctlptl apply -f hack/kind/cluster.yaml
	helm repo list | grep argo || helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm upgrade argocd argo/argo-cd \
		--version 3.35.4 \
		--install \
		--create-namespace \
		--namespace argocd \
		--values hack/argo-cd-config/values.yaml \
		--wait \
		--timeout 300s
	kubectl apply -f hack/argo-cd-apps/repositories.yaml
	kubectl apply -f hack/argo-cd-apps/apps.yaml

.PHONY: hack-kind-down
hack-kind-down:
	ctlptl delete -f hack/kind/cluster.yaml

################################################################################
# Kubebuilder stuffs                                                           #
################################################################################

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen

## Tool Versions
CONTROLLER_TOOLS_VERSION ?= v0.9.0

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	echo $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=charts/k8sta/templates/crds

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."