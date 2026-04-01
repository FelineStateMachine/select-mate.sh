SHELL := /bin/bash

TEST_ROOT ?= /tmp/select-mate-live
TEST_BOARD_PATH := $(TEST_ROOT)/shared/game.db
TEST_BOARD_URI := file:$(TEST_BOARD_PATH)?mode=rwc
TEST_CONFIG_ROOT := $(TEST_ROOT)/config
TEST_ALICE_CONFIG := $(TEST_CONFIG_ROOT)/alice
TEST_BOB_CONFIG := $(TEST_CONFIG_ROOT)/bob

.PHONY: help test-prepare test-reset test-board-uri alice bob test-alice test-bob

help:
	@printf '%s\n' \
		'make alice        Open the shared live-test board as alice.' \
		'make bob          Open the shared live-test board as bob.' \
		'make test-prepare Create the shared board/config layout.' \
		'make test-reset   Remove the shared live-test board and configs.' \
		'make test-board-uri Print the shared board URI.'

test-prepare:
	@mkdir -p "$(dir $(TEST_BOARD_PATH))" "$(TEST_ALICE_CONFIG)" "$(TEST_BOB_CONFIG)"
	@printf 'identity=alice\n' > "$(TEST_ALICE_CONFIG)/select-mate.conf"
	@printf 'identity=bob\n' > "$(TEST_BOB_CONFIG)/select-mate.conf"
	@printf '%s\n' "$(TEST_BOARD_URI)" | ./select-mate.sh --whoami >/dev/null
	@printf 'Shared board: %s\n' "$(TEST_BOARD_URI)"
	@printf 'Alice config: %s\n' "$(TEST_ALICE_CONFIG)/select-mate.conf"
	@printf 'Bob config: %s\n' "$(TEST_BOB_CONFIG)/select-mate.conf"
	@printf '%s\n' 'Open one terminal with `make alice` and another with `make bob`.'

test-reset:
	@rm -rf "$(TEST_ROOT)"
	@printf 'Removed %s\n' "$(TEST_ROOT)"

test-board-uri:
	@printf '%s\n' "$(TEST_BOARD_URI)"

alice: test-prepare
	@printf '%s\n' "$(TEST_BOARD_URI)" | XDG_CONFIG_HOME="$(TEST_ALICE_CONFIG)" ./select-mate.sh --identity alice

bob: test-prepare
	@printf '%s\n' "$(TEST_BOARD_URI)" | XDG_CONFIG_HOME="$(TEST_BOB_CONFIG)" ./select-mate.sh --identity bob

test-alice: alice

test-bob: bob
