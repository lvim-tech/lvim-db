.PHONY: test fmt

# The XDG homes are redirected into a throwaway directory first, so a spec that
# opens a store or writes a cache cannot reach the real editor's data;
# tests/run.lua refuses to run without that redirection.
#
# The suite runs in a bare headless nvim: no config, no plugins, no framework.
# With $LODE_DAEMON pointing at a `loded` binary the engine specs run too;
# without it they skip, so `make test` works on a machine with no engine built.
test:
	@LVIM_TEST_HOME="$$(mktemp -d)" ; \
	XDG_DATA_HOME="$$LVIM_TEST_HOME/data" \
	XDG_STATE_HOME="$$LVIM_TEST_HOME/state" \
	XDG_CACHE_HOME="$$LVIM_TEST_HOME/cache" \
	XDG_CONFIG_HOME="$$LVIM_TEST_HOME/config" \
	LVIM_TEST_HOME="$$LVIM_TEST_HOME" \
	nvim --headless -u NONE -l tests/run.lua ; \
	status=$$? ; rm -rf "$$LVIM_TEST_HOME" ; exit $$status

fmt:
	stylua lua tests
