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
	_build/prod/rel/fast_api/bin/fast_api start

# end
