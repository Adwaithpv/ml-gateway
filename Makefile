.PHONY: all train build deploy test retrain clean

all: train build deploy

train:
	cd services/small && python train.py
	cd services/medium && python train.py
	cd services/large && python train.py

build:
	docker build -t ml-gateway/small:latest services/small/
	docker build -t ml-gateway/medium:latest services/medium/
	docker build -t ml-gateway/large:latest services/large/
	docker build -t ml-gateway/gateway:latest gateway/

deploy:
	kubectl apply -f k8s/

test:
	curl -X POST http://localhost:30080/classify -H 'Content-Type: application/json' -d '{"text": "Congratulations! You won a free prize", "latency_budget_ms": 100}'
	curl http://localhost:30080/health
	curl http://localhost:30080/models

retrain:
	kubectl apply -f k8s/retrain-job.yaml

clean:
	kubectl delete -f k8s/ --ignore-not-found
	docker rmi ml-gateway/small:latest ml-gateway/medium:latest ml-gateway/large:latest ml-gateway/gateway:latest || true
