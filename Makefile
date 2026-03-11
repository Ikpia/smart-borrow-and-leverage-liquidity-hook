SHELL := /bin/bash

.PHONY: bootstrap build test fuzz invariant coverage abis frontend \
	deploy-local deploy-testnet deploy-unichain \
	demo-local demo-testnet demo-leverage demo-liquidate demo-all \
	verify-commits verify-deps

bootstrap:
	./scripts/bootstrap.sh

build:
	forge build

test:
	forge test

fuzz:
	forge test --match-path test/fuzz/ProtocolFuzz.t.sol

invariant:
	forge test --match-path test/fuzz/ProtocolInvariants.t.sol

coverage:
	./scripts/ensure_coverage_100.sh

abis:
	./scripts/export_abis.sh

frontend:
	python3 -m http.server 4173

deploy-local:
	forge script script/deploy/DeployProtocol.s.sol:DeployProtocolScript \
		--rpc-url $${RPC_URL:-http://127.0.0.1:8545} \
		--private-key $$PRIVATE_KEY --broadcast -vvv

deploy-testnet:
	forge script script/deploy/DeployProtocolUnichain.s.sol:DeployProtocolUnichainScript \
		--rpc-url $$SEPOLIA_RPC_URL \
		--private-key $$PRIVATE_KEY --broadcast -vvv

deploy-unichain:
	./scripts/deploy-unichain.sh

demo-local:
	./scripts/demo-local.sh

demo-testnet:
	./scripts/demo-testnet.sh all

demo-leverage:
	./scripts/demo-leverage.sh

demo-liquidate:
	./scripts/demo-liquidate.sh

demo-all:
	./scripts/demo-testnet.sh all

verify-commits:
	./scripts/verify_commits.sh

verify-deps:
	./scripts/bootstrap.sh
