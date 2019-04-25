
stop:
	@venv/bin/docker-compose down

setup_and_start: venv stop
	@venv/bin/docker-compose run -d --service-ports vault
	@echo "Vault started, waiting a few seconds to set up PKI and create certs"
	@sleep 10
	@./setup.sh
	@echo "Starting nginx with mTLS enabled"
	@venv/bin/docker-compose run -d --service-ports nginx
	@sleep 1
	@curl -k --cacert ./client/ca.crt --cert ./client/client.crt --key ./client/client.key https://localhost

venv:
	virtualenv venv
	venv/bin/pip install docker-compose
