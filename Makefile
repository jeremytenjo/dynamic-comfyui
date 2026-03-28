IMAGE_REF ?= avatary-image-generator-v1:smoke-local
BUILD_PLATFORM ?= linux/amd64

.PHONY: smoke-local smoke-runpod

smoke-local:
	IMAGE_REF="$(IMAGE_REF)" BUILD_PLATFORM="$(BUILD_PLATFORM)" bash scripts/smoke-local.sh

smoke-runpod:
	bash scripts/smoke-runpod.sh
