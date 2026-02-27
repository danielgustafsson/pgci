# src/test/modules/test_memcontext_reporting/Makefile

TAP_TESTS = 1

EXTRA_INSTALL = src/test/modules/injection_points

export enable_injection_points
MODULE_big = test_memcontext_reporting
OBJS = \
   $(WIN32RES) \
   test_memcontext_reporting.o
PGFILEDESC = "test_memcontext_reporting - test code for memory context reporting"

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = src/test/modules/test_memcontext_reporting
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
