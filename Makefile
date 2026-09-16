.DEFAULT_GOAL := help
SHELL := /bin/bash

LOAD_ENV = set -e; source syncprod;

.PHONY: help upgrade-schedule upgrade-execute upgrade-schedule-dry-run upgrade-execute-dry-run
.PHONY: migrate-schedule migrate-execute migrate-schedule-dry-run migrate-execute-dry-run

help:
	@printf '%s\n' \
		'upgrade-schedule-dry-run  Simulate scheduling using ADMIN and RPC_URL.' \
		'upgrade-schedule          Schedule through Fireblocks using ADMIN; confirm using RPC_URL.' \
		'upgrade-execute-dry-run   Simulate execution using RPC_URL and PRIVATE_KEY.' \
		'upgrade-execute           Execute using RPC_URL and PRIVATE_KEY.' \
		'migrate-schedule-dry-run  Simulate scheduling using MIGRATION_PROPOSER and RPC_URL.' \
		'migrate-schedule          Schedule through Fireblocks using MIGRATION_PROPOSER; confirm using RPC_URL.' \
		'migrate-execute-dry-run   Simulate execution using RPC_URL and PRIVATE_KEY.' \
		'migrate-execute           Execute using RPC_URL and PRIVATE_KEY.' \
		'Targets load environment settings with source syncprod.'

upgrade-schedule-dry-run:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${ADMIN:?Set ADMIN to the Fireblocks proposer address}"; \
		forge script script/v2/upgrade/ScheduleV2Upgrade.s.sol:ScheduleV2Upgrade \
			--sender "$$ADMIN" --slow --rpc-url "$$RPC_URL"

upgrade-schedule:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${ADMIN:?Set ADMIN to the Fireblocks proposer address}"; \
		fireblocks-json-rpc --http -- \
			forge script script/v2/upgrade/ScheduleV2Upgrade.s.sol:ScheduleV2Upgrade \
			--sender "$$ADMIN" --slow --broadcast --unlocked --rpc-url {}
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		forge script script/v2/upgrade/ScheduleV2Upgrade.s.sol:ScheduleV2Upgrade \
			--sig 'checkScheduled()' --rpc-url "$$RPC_URL"

upgrade-execute-dry-run:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${PRIVATE_KEY:?Set PRIVATE_KEY before running this target}"; \
		forge script script/v2/upgrade/ExecuteV2Upgrade.s.sol:ExecuteV2Upgrade \
			--rpc-url "$$RPC_URL" --private-key "$$PRIVATE_KEY"

upgrade-execute:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${PRIVATE_KEY:?Set PRIVATE_KEY before running this target}"; \
		forge script script/v2/upgrade/ExecuteV2Upgrade.s.sol:ExecuteV2Upgrade \
			--rpc-url "$$RPC_URL" --private-key "$$PRIVATE_KEY" --broadcast
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		forge script script/v2/upgrade/ExecuteV2Upgrade.s.sol:ExecuteV2Upgrade \
			--sig 'checkExecuted()' --rpc-url "$$RPC_URL"

migrate-schedule-dry-run:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${MIGRATION_PROPOSER:?Set MIGRATION_PROPOSER to the Fireblocks migration proposer address}"; \
		forge script script/v2/migrate/ScheduleV2Migration.s.sol:ScheduleV2Migration \
			--sender "$$MIGRATION_PROPOSER" --slow --rpc-url "$$RPC_URL"

migrate-schedule:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${MIGRATION_PROPOSER:?Set MIGRATION_PROPOSER to the Fireblocks migration proposer address}"; \
		fireblocks-json-rpc --http -- \
			forge script script/v2/migrate/ScheduleV2Migration.s.sol:ScheduleV2Migration \
			--sender "$$MIGRATION_PROPOSER" --slow --broadcast --unlocked --rpc-url {}
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		forge script script/v2/migrate/ScheduleV2Migration.s.sol:ScheduleV2Migration \
			--sig 'checkScheduled()' --rpc-url "$$RPC_URL"

migrate-execute-dry-run:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${PRIVATE_KEY:?Set PRIVATE_KEY before running this target}"; \
		forge script script/v2/migrate/ExecuteV2Migration.s.sol:ExecuteV2Migration \
			--rpc-url "$$RPC_URL" --private-key "$$PRIVATE_KEY"

migrate-execute:
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		: "$${PRIVATE_KEY:?Set PRIVATE_KEY before running this target}"; \
		forge script script/v2/migrate/ExecuteV2Migration.s.sol:ExecuteV2Migration \
			--rpc-url "$$RPC_URL" --private-key "$$PRIVATE_KEY" --broadcast
	@$(LOAD_ENV) \
		: "$${RPC_URL:?Set RPC_URL before running this target}"; \
		forge script script/v2/migrate/ExecuteV2Migration.s.sol:ExecuteV2Migration \
			--sig 'checkExecuted()' --rpc-url "$$RPC_URL"
