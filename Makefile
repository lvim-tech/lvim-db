.PHONY: test fmt

# The suite runs in a bare headless nvim: no config, no plugins, no framework.
# With $LODE_DAEMON pointing at a `loded` binary the engine specs run too;
# without it they skip, so `make test` works on a machine with no engine built.
test:
	nvim --headless -u NONE -l tests/run.lua

fmt:
	stylua lua tests
