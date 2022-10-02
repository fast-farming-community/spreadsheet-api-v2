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

# end
