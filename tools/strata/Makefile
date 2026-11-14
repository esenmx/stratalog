.PHONY: check lint test e2e

check: lint test e2e

lint:
	golangci-lint run ./...

test:
	go test -race -count=1 ./...

e2e:
	bash e2e.sh
