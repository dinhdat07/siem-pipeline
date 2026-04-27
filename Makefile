.PHONY: up down demo demo-hot demo-cold demo-detect smoke smoke-hot smoke-cold smoke-detect logs

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

logs:
	docker compose logs -f --tail=200
