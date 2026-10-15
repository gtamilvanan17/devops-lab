# Thin wrapper so you can type `make up` instead of `./lab.sh up`.
.PHONY: up start stop status creds verify sync init configs destroy lint

up start stop status creds verify sync init configs:
	./lab.sh $@

destroy:
	./lab.sh destroy

# Syntax check, plus shellcheck when it is installed.
lint:
	bash -n lab.sh
	@command -v shellcheck >/dev/null && shellcheck lab.sh || echo "shellcheck not installed (brew install shellcheck)"
