.PHONY: up down groundcover break-slow-db fix-slow-db break-errors fix-errors break-oom fix-oom fix smoke

up:
	./setup.sh

down:
	./teardown.sh

groundcover:
	./scripts/install-groundcover.sh

break-slow-db:
	./scenarios/slow-db.sh on

fix-slow-db:
	./scenarios/slow-db.sh off

break-errors:
	./scenarios/error-spike.sh on

fix-errors:
	./scenarios/error-spike.sh off

break-oom:
	./scenarios/oom.sh on

fix-oom:
	./scenarios/oom.sh off

fix:
	./scenarios/slow-db.sh off
	./scenarios/error-spike.sh off
	./scenarios/oom.sh off

smoke:
	./scripts/smoke.sh
