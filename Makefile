##
# Fast API
#
# @file
# @version 0.1

.PHONY: run-dev
run-dev:
	MIX_ENV=dev mix phx.server

.PHONY: deps
deps:
	mix deps.get

.PHONY: deps-update
deps-update:
	mix deps.update --all

.PHONY: build-prod
build-prod:
	MIX_ENV=prod mix release

.PHONY: run-prod
run-prod: build-prod
	_build/prod/rel/fast_api/bin/fast_api daemon

.PHONY: test-local-up
test-local-up:
	podman-compose -f docker/docker-compose.yaml up -d

.PHONY: test-local-down
test-local-down:
	podman-compose -f docker/docker-compose.yaml down --remove-orphans

.PHONY: test-local-env
test-local-env: test-local-down test-local-up

.PHONY: test-local-logs
test-local-logs:
	podman-compose -f docker/docker-compose.yaml logs ${ARG}

# end
