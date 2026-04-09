SHELL := bash

.PHONY: setup format lint test build help

setup:
	./scripts/setup.sh

format:
	./scripts/format.sh

lint:
	./scripts/lint.sh

test:
	./scripts/test.sh

build:
	./scripts/build.sh

help:
	@echo "Available targets:"
	@echo "  make setup   - Setup development environment"
	@echo "  make format - Format code"
	@echo "  make lint   - Run linter"
	@echo "  make test   - Run tests"
	@echo "  make build  - Build project"
	@echo "  make help   - Show this help message"
