.PHONY: help up down test app-test lint diagram
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'
up: ## build EVERYTHING end to end and prove it works
	./scripts/up.sh
down: ## delete EVERYTHING this repo created
	./scripts/down.sh
test: ## live test suite against the deployed platform
	./scripts/test.sh
app-test: ## unit tests
	PYTHONPATH=app .venv/bin/pytest app/tests -q
lint: ## ruff, terraform fmt+validate, shellcheck
	.venv/bin/ruff check app scripts/mcp_client.py && .venv/bin/ruff format --check app scripts/mcp_client.py
	terraform -chdir=terraform fmt -check -recursive && terraform -chdir=terraform validate
	shellcheck -S warning -x scripts/*.sh
diagram: ## regenerate docs/img/architecture.{svg,png}
	python3 docs/diagrams/architecture.py && .venv/bin/python3 docs/diagrams/render.py docs/img/architecture.svg docs/img/architecture.png
