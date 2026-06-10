.PHONY: help tidy build run vet test docker-up docker-down zoho-spike backup

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

tidy:        ## go mod tidy
	cd backend && go mod tidy

build:       ## compile the API server
	cd backend && go build -o bin/server ./cmd/server

vet:         ## go vet
	cd backend && go vet ./...

run:         ## run the API locally (needs a reachable Postgres + .env)
	cd backend && go run ./cmd/server

zoho-spike:  ## run the Zoho validation spike (needs real Zoho creds in env)
	cd backend && go run ./cmd/zoho-spike

docker-up:   ## start the full stack (postgres + api + nginx)
	docker compose up -d --build

docker-down: ## stop the stack
	docker compose down

backup:      ## nightly-style pg_dump to ./backups
	./scripts/backup.sh
