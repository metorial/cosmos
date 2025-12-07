.PHONY: all proto build test clean docker e2e-test e2e-up e2e-down e2e-reset

all: proto build

proto:
	@echo "Generating protobuf code..."
	@mkdir -p internal/proto
	protoc --go_out=. --go_opt=paths=source_relative \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		internal/proto/cosmos.proto

build: proto
	@echo "Building cosmos-controller..."
	go build -o bin/cosmos-controller cmd/cosmos-controller/main.go
	@echo "Building cosmos-agent..."
	go build -o bin/cosmos-agent cmd/cosmos-agent/main.go

test:
	@echo "Running tests..."
	go test -v -race -coverprofile=coverage.out ./...

integration-test:
	@echo "Running integration tests..."
	go test -v -race ./test/integration/...

lint:
	@echo "Running linters..."
	golangci-lint run

clean:
	@echo "Cleaning..."
	rm -rf bin/
	rm -f coverage.out

docker-controller:
	@echo "Building controller Docker image..."
	docker build -f infra/controller/Dockerfile -t cosmos-controller:latest .

docker-agent:
	@echo "Building agent Docker image..."
	docker build -f infra/agent/Dockerfile -t cosmos-agent:latest .

docker: docker-controller docker-agent

install-tools:
	@echo "Installing development tools..."
	go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
	go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest

deps:
	@echo "Downloading dependencies..."
	go mod download
	go mod tidy

dev-setup: install-tools deps
	@echo "Development environment ready!"

e2e-up:
	@echo "Starting E2E test environment..."
	docker compose -f docker-compose.test.yml up -d --build
	@echo "Waiting for services to be ready..."
	sleep 15

e2e-down:
	@echo "Stopping E2E test environment..."
	docker compose -f docker-compose.test.yml down

e2e-reset:
	@echo "Resetting E2E test environment..."
	docker compose -f docker-compose.test.yml down -v
	docker compose -f docker-compose.test.yml up -d --build
	@echo "Waiting for services to be ready..."
	sleep 15

e2e-test:
	@echo "Running E2E tests..."
	docker compose -f docker-compose.test.yml run --rm e2e-tests go test -v ./test/e2e/... -timeout 10m

e2e-logs:
	@echo "Showing logs..."
	docker compose -f docker-compose.test.yml logs -f

e2e-test-local:
	@echo "Running E2E tests locally (requires running infrastructure)..."
	COSMOS_CONTROLLER_URL=http://localhost:8090 go test -v ./test/e2e/... -timeout 10m
