FRONTEND_DIR = ./web
BACKEND_DIR = .

.PHONY: all build-frontend start-backend

all: build-frontend start-backend

build-frontend:
	@echo "Building frontend..."
	@cd $(FRONTEND_DIR) && \
		bun pm trust @douyinfe/semi-ui @douyinfe/semi-icons @douyinfe/vite-plugin-semi && \
		bun install && \
		DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION=$(shell cat VERSION) bun run build

start-backend:
	@echo "Starting backend dev server..."
	@cd $(BACKEND_DIR) && go run main.go &
