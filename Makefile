ERLC = erlc
ERL = erl
SOURCES = pastry_util.erl pastry_node.erl project3.erl project3_bonus.erl benchmark_scale.erl test_pastry.erl test_network.erl
BEAMS = $(SOURCES:.erl=.beam)

ifeq ($(OS),Windows_NT)
	CLEAN_CMD = del /f /q *.beam *.dump erl_crash.dump 2>nul || exit 0
else
	CLEAN_CMD = rm -f *.beam *.dump erl_crash.dump
endif

all: $(BEAMS)

%.beam: %.erl
	$(ERLC) $<

test: all
	$(ERL) -noshell -pa . -s test_pastry run -s init stop
	$(ERL) -noshell -pa . -eval "test_network:run(50, 5), halt()."

scale: all
	$(ERL) -noshell -pa . -s benchmark_scale run -s init stop

bonus: all
	$(ERL) -noshell -pa . -s project3_bonus run_benchmark -s init stop

clean:
	-$(CLEAN_CMD)
