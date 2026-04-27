.PHONY: up down demo demo-hot demo-cold demo-detect smoke smoke-hot smoke-cold smoke-detect benchmark-small benchmark-medium benchmark-large logs

up:
	docker compose up -d --build

down:
	docker compose down

demo:
	bash scripts/demo/run-demo.sh full

demo-hot:
	bash scripts/demo/run-demo.sh hot-only

demo-cold:
	bash scripts/demo/run-demo.sh cold-only

demo-detect:
	bash scripts/demo/run-demo.sh detect-only

smoke:
	bash scripts/smoke/run_smoke_tests.sh full

smoke-hot:
	bash scripts/smoke/run_smoke_tests.sh hot

smoke-cold:
	bash scripts/smoke/run_smoke_tests.sh cold

smoke-detect:
	bash scripts/smoke/run_smoke_tests.sh detect

benchmark-small:
	bash scripts/benchmark/run_benchmark.sh small

benchmark-medium:
	bash scripts/benchmark/run_benchmark.sh medium

benchmark-large:
	bash scripts/benchmark/run_benchmark.sh large

logs:
	docker compose logs -f --tail=200
